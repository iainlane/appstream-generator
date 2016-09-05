/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module handlers.desktopparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format, indexOf, chomp, lastIndexOf, toStringz;
import std.array : split, empty;
import std.algorithm : startsWith, endsWith, strip, stripRight;
import std.stdio;
import glib.KeyFile;
import appstream.Component;
import appstream.Provided;
import appstream.Icon;
static import std.regex;

import result;
import utils;
import config : Config, FormatVersion;

private string getLocaleFromKey (string key)
{
    if (!localeValid (key))
        return null;
    auto si = key.indexOf ("[");

    // check if this key is language-specific, if not assume untranslated.
    if (si <= 0)
        return "C";

    auto locale = key[si+1..$-1];
    // drop UTF-8 suffixes
    locale = chomp (locale, ".utf-8");
    locale = chomp (locale, ".UTF-8");

    auto delim = locale.lastIndexOf ('.');
    if (delim > 0) {
        // looks like we need to drop another encoding suffix
        // (but we need to make sure it actually is one)
        auto enc = locale[delim+1..$];
        if ((enc !is null) && (enc.toLower ().startsWith ("iso"))) {
            locale = locale[0..delim];
        }
    }

    return locale;
}

private string getValue (KeyFile kf, string key)
{
    string val;
    try {
        val = kf.getString (DESKTOP_GROUP, key);
    } catch {
        val = null;
    }

    // some dumb .desktop files contain non-printable characters. If we are in XML mode,
    // this will hard-break the XML reader at a later point, so we need to clean this up
    // and replace these characters with a nice questionmark, so someone will clean them up.
    // TODO: Maybe even emit an issue hint if a non-printable chacater is found?
    auto re = std.regex.ctRegex!(r"[\x00\x08\x0B\x0C\x0E-\x1F]", "g");
    val = std.regex.replaceAll (val, re, "#?#");

    return val;
}

/**
 * Filter out some useless categories which we don't want to have in the
 * AppStream metadata.
 */
private string[] filterCategories (Component cpt, GeneratorResult gres, const(string[]) cats)
{
    import bindings.appstream_utils;

    string[] rescats;
    foreach (string cat; cats) {
        switch (cat) {
            case "GTK":
            case "Qt":
            case "GNOME":
            case "KDE":
            case "GUI":
            case "Application":
                break;
            default:
                if (!cat.empty && !cat.toLower.startsWith ("x-")) {
                    if (as_utils_is_category_name (cat.toStringz))
                        rescats ~= cat;
                    else
                        gres.addHint (cpt, "category-name-invalid", ["category": cat]);
                }

        }
    }

    return rescats;
}

Component parseDesktopFile (GeneratorResult gres, string fname, string data, bool ignore_nodisplay = false)
{
    auto fnameBase = baseName (fname);

    auto df = new KeyFile ();
    try {
        df.loadFromData (data, -1, GKeyFileFlags.KEEP_TRANSLATIONS);
    } catch (Exception e) {
        // there was an error
        gres.addHint (fnameBase, "desktop-file-error", e.msg);
        return null;
    }

    try {
        // check if we should ignore this .desktop file
        auto dtype = df.getString (DESKTOP_GROUP, "Type");
        if (dtype.toLower () != "application") {
            // ignore this file, it isn't describing an application
            return null;
        }
    } catch {}

    try {
        auto nodisplay = df.getString (DESKTOP_GROUP, "NoDisplay");
        if ((!ignore_nodisplay) && (nodisplay.toLower () == "true")) {
                // we ignore this .desktop file, shouldn't be displayed
                return null;
        }
    } catch {}

    try {
        auto asignore = df.getString (DESKTOP_GROUP, "X-AppStream-Ignore");
        if (asignore.toLower () == "true") {
            // this .desktop file should be excluded from AppStream metadata
            return null;
        }
    } catch {
        // we don't care if non-essential tags are missing.
        // if they are not there, the file should be processed.
    }

    /* check this is a valid desktop file */
	if (!df.hasGroup (DESKTOP_GROUP)) {
        gres.addHint (fnameBase,
                     "desktop-file-error",
                     format ("Desktop file '%s' is not a valid desktop file.", fname));
        return null;
	}

    // make sure we have a valid component to work on
    auto cpt = gres.getComponent (fnameBase);
    if (cpt is null) {
        cpt = new Component ();
        // strip .desktop suffix if the reverse-domain-name scheme is followed and we build for
        // a high AppStream version.
        if (Config.get ().formatVersion >= FormatVersion.V0_10) {
            immutable parts = fnameBase.split (".");
            if (isTopLevelDomain (parts[0]))
                cpt.setId (fnameBase[0..$-8]);
            else
                cpt.setId (fnameBase);
        } else {
            cpt.setId (fnameBase);
        }
        cpt.setKind (ComponentKind.DESKTOP_APP);
        gres.addComponent (cpt);
    }

    void checkDesktopString (string fieldId, string str)
    {
        if (((str.startsWith ("\"")) && (str.endsWith ("\""))) ||
            ((str.startsWith ("\'")) && (str.endsWith ("\'")))) {
                gres.addHint (cpt, "metainfo-quoted-value", ["value": str, "field": fieldId]);
            }
    }

    size_t dummy;
    auto keys = df.getKeys (DESKTOP_GROUP, dummy);
    foreach (string key; keys) {
        string locale;
        locale = getLocaleFromKey (key);
        if (locale is null)
            continue;

        if (key.startsWith ("Name")) {
            immutable val = getValue (df, key);
            checkDesktopString (key, val);
            /* run backend specific hooks */
            auto translations = gres.pkg.processDesktopFile (df, val);
            translations[locale] = val;
            foreach (key, value; translations)
                cpt.setName (value, key);
        } else if (key.startsWith ("Comment")) {
            immutable val = getValue (df, key);
            checkDesktopString (key, val);
            auto translations = gres.pkg.processDesktopFile (df, val);
            translations[locale] = val;
            foreach (key, value; translations)
                cpt.setSummary (value, key);
        } else if (key == "Categories") {
            auto value = getValue (df, key);
            auto cats = value.split (";");
            cats = filterCategories (cpt, gres, cats);
            if (cats.empty)
                continue;

            foreach (ref c; cats)
                cpt.addCategory (c);
        } else if (key.startsWith ("Keywords")) {
            auto val = getValue (df, key);
            auto translations = gres.pkg.processDesktopFile (df, val);
            translations[locale] = val;
            foreach (key, value; translations) {
                auto kws = value.split (";").stripRight ("");
                if (kws.empty)
                    continue;
                cpt.setKeywords (kws, key);
            }
        } else if (key == "MimeType") {
            auto value = getValue (df, key);
            immutable mts = value.split (";");
            if (mts.empty)
                continue;

            Provided prov = cpt.getProvidedForKind (ProvidedKind.MIMETYPE);
            if (prov is null) {
                prov = new Provided ();
                prov.setKind (ProvidedKind.MIMETYPE);
            }

            foreach (ref mt; mts) {
                if (!mt.empty)
                    prov.addItem (mt);
            }
            cpt.addProvided (prov);
        } else if (key == "Icon") {
            auto icon = new Icon ();
            icon.setKind (IconKind.CACHED);
            // icons with 0x0 dimensions won't be added, so to temporarily store the icon
            // until it is processed by the IconHandler, we set it's size to 1x1px
            icon.setWidth (1);
            icon.setHeight (1);
            icon.setName (getValue (df, key));
            cpt.addIcon (icon);
        }
    }

    return cpt;
}

unittest
{
    import std.stdio : writeln;
    import backends.dummy.dummypkg;
    writeln ("TEST: ", ".desktop file parser");

    auto data = """
[Desktop Entry]
Name=FooBar
Name[de_DE]=FööBär
Comment=A foo-ish bar.
Keywords=Flubber;Test;Meh;
Keywords[de_DE]=Goethe;Schiller;Kant;
""";

    auto pkg = new DummyPackage ("pkg", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);
    auto cpt = parseDesktopFile (res, "foobar.desktop", data, false);
    assert (cpt !is null);

    cpt = res.getComponent ("foobar.desktop");
    assert (cpt !is null);

    assert (cpt.getName () == "FooBar");
    assert (cpt.getKeywords () == ["Flubber", "Test", "Meh"]);

    cpt.setActiveLocale ("de_DE");
    assert (cpt.getName () == "FööBär");
    assert (cpt.getKeywords () == ["Goethe", "Schiller", "Kant"]);

    // test component-id trimming
    res = new GeneratorResult (pkg);
    cpt = parseDesktopFile (res, "org.example.foobar.desktop", data, false);
    assert (cpt !is null);

    cpt = res.getComponent ("org.example.foobar");
    assert (cpt !is null);

    // legacy
    Config.get ().formatVersion = FormatVersion.V0_8;
    res = new GeneratorResult (pkg);
    cpt = parseDesktopFile (res, "org.example.foobar.desktop", data, false);
    assert (cpt !is null);

    cpt = res.getComponent ("org.example.foobar.desktop");
    assert (cpt !is null);
    Config.get ().formatVersion = FormatVersion.V0_10;
}
