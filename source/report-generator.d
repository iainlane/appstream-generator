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

module ag.reportgenerator;

import std.stdio;
import std.string;
import std.parallelism;
import std.path : buildPath, buildNormalizedPath;
import std.file : mkdirRecurse;
import std.array : empty;
import std.json;
import mustache;

import ag.config;
import ag.logging;
import ag.hint;
import ag.backend.intf;
import ag.datacache;


private alias MustacheEngine!(string) Mustache;

class ReportGenerator
{

private:
    Config conf;
    PackageIndex pkgIndex;
    DataCache dcache;

    string exportDir;
    string htmlExportDir;
    string templateDir;

    Mustache mustache;

    struct HintTag
    {
        string tag;
        string message;
    }

    struct HintEntry
    {
        string identifier;
        string[] archs;
        HintTag[] errors;
        HintTag[] warnings;
        HintTag[] infos;
    }

    struct PkgSummary
    {
        string pkgname;
        int infoCount;
        int warningCount;
        int errorCount;
    }

    struct DataSummary
    {
        PkgSummary[][string] pkgSummaries;
        HintEntry[string][string] hintEntries;
        long totalInfos;
        long totalWarnings;
        long totalErrors;
    }

public:

    this (DataCache dcache)
    {
        this.conf = Config.get ();

        exportDir = buildPath (conf.workspaceDir, "export");
        htmlExportDir = buildPath (exportDir, "html");

        // we need the data cache to get hint and metainfo data
        this.dcache = dcache;

        // find a suitable template directory

        // first check the workspace
        auto tdir = buildPath (conf.workspaceDir, "templates");
        tdir = getVendorTemplateDir (tdir, true);

        if (tdir is null) {
            auto exeDir = dirName (std.file.thisExePath ());
            tdir = buildNormalizedPath (exeDir, "..", "data", "templates");

            tdir = getVendorTemplateDir (tdir);
            if (tdir is null) {
                tdir = getVendorTemplateDir ("/usr/share/appstream/templates");
            }
        }

        templateDir = tdir;
        mustache.path = templateDir;
        mustache.ext = "html";
    }

    private static bool isDir (string path)
    {
        if (std.file.exists (path))
            if (std.file.isDir (path))
                return true;
        return false;
    }

    private string getVendorTemplateDir (string dir, bool allowRoot = false)
    {
        string tdir;
        if (conf.projectName !is null) {
            tdir = buildPath (dir, conf.projectName);
            if (isDir (tdir))
                return tdir;
        }
        tdir = buildPath (dir, "default");
        if (isDir (tdir))
            return tdir;
        if (allowRoot) {
            if (isDir (dir))
                return dir;
        }

        return null;
    }

    private string[] splitBlockData (string str, string blockType)
    {
        auto content = str.strip ();
        string blockName;
        if (content.startsWith ("{")) {
            auto li = content.indexOf("}");
            if (li <= 0)
                throw new Exception ("Invalid %s: Closing '}' missing.", blockType);
            blockName = content[1..li].strip ();
            if (li+1 >= content.length)
                content = "";
            else
                content = content[li+1..$];
        }

        if (blockName is null)
            throw new Exception ("Invalid %s: Does not have a name.", blockType);

        return [blockName, content];
    }

    private void setupMustacheContext (Mustache.Context context)
    {
        string[string] partials;

        // this implements a very cheap way to get template inheritance
        // would obviously be better if our template system would support this natively.
        context["partial"] = (string str) {
            auto split = splitBlockData (str, "partial");
            partials[split[0]] = split[1];
            return "";
        };

        context["block"] = (string str) {
            auto split = splitBlockData (str, "block");
            auto blockName = split[0];
            str = split[1] ~ "\n";

            auto partialCP = (blockName in partials);
            if (partialCP is null)
                return str;
            else
                return *partialCP;
        };

        auto time = std.datetime.Clock.currTime ();
        auto timeStr = format ("%d-%02d-%02d %02d:%02d [%s]", time.year, time.month, time.day, time.hour,time.minute, time.timezone.name);

        context["time"] = timeStr;
        context["generator_version"] = 0.1;
        context["project_name"] = conf.projectName;
        context["root_url"] = conf.htmlBaseUrl;
    }

    private void renderPage (string pageID, string exportName, Mustache.Context context)
    {
        setupMustacheContext (context);

        auto fname = buildPath (htmlExportDir, exportName) ~ ".html";
        mkdirRecurse (dirName (fname));

        logDebug ("Rendering HTML page: %s", exportName);
        auto data = mustache.render (pageID, context).strip ();
        auto f = File (fname, "w");
        f.writeln (data);
    }

    private void renderPagesFor (string suiteName, string section, DataSummary dsum)
    {
        if (templateDir is null) {
            logError ("Can not render HTML: No page templates found.");
            return;
        }

        logInfo ("Rendering HTML for %s/%s", suiteName, section);
        // write issue hint pages
        foreach (pkgname; dsum.hintEntries.byKey ()) {
            auto pkgHEntries = dsum.hintEntries[pkgname];
            auto exportName = format ("%s/%s/hints/%s", suiteName, section, pkgname);

            auto context = new Mustache.Context;
            context["suite"] = suiteName;
            context["package_name"] = pkgname;
            context["section"] = section;

            context["entries"] = (string content) {
                string res;
                foreach (cid; pkgHEntries.byKey ()) {
                    auto hentry = pkgHEntries[cid];
                    auto intCtx = new Mustache.Context;
                    intCtx["component_id"] = cid;

                    foreach (arch; hentry.archs) {
                        auto archSub = intCtx.addSubContext("architectures");
                        archSub["arch"] = arch;
                    }

                    if (!hentry.errors.empty)
                        intCtx["has_errors"] = ["has_errors": "yes"];
                    foreach (error; hentry.errors) {
                        auto errSub = intCtx.addSubContext("errors");
                        errSub["error_tag"] = error.tag;
                        errSub["error_description"] = error.message;
                    }

                    if (!hentry.warnings.empty)
                        intCtx["has_warnings"] = ["has_warnings": "yes"];
                    foreach (warning; hentry.warnings) {
                        auto warnSub = intCtx.addSubContext("warnings");
                        warnSub["warning_tag"] = warning.tag;
                        warnSub["warning_description"] = warning.message;
                    }

                    if (!hentry.infos.empty)
                        intCtx["has_infos"] = ["has_infos": "yes"];
                    foreach (info; hentry.infos) {
                        auto infoSub = intCtx.addSubContext("infos");
                        infoSub["info_tag"] = info.tag;
                        infoSub["info_description"] = info.message;
                    }

                    res ~= mustache.renderString (content, intCtx);
                }

                return res;
            };

            renderPage ("issues_page", exportName, context);
        }

        // write hint overview page
        auto hindexExportName = format ("%s/%s/hints/index", suiteName, section);
        auto summaryCtx = new Mustache.Context;
        summaryCtx["suite"] = suiteName;
        summaryCtx["section"] = section;

        summaryCtx["summaries"] = (string content) {
            string res;

            foreach (maintainer; dsum.pkgSummaries.byKey ()) {
                auto summaries = dsum.pkgSummaries[maintainer];
                auto intCtx = new Mustache.Context;
                intCtx["maintainer"] = maintainer;
                foreach (summary; summaries) {
                    auto maintSub = intCtx.addSubContext("packages");
                    maintSub["pkgname"] = summary.pkgname;

                    // again, we use this dumb hack to allow conditionals in the Mustache
                    // template.
                    if (summary.infoCount > 0)
                        maintSub["has_info_count"] =["has_count": "yes"];
                    if (summary.warningCount > 0)
                        maintSub["has_warning_count"] =["has_count": "yes"];
                    if (summary.errorCount > 0)
                        maintSub["has_error_count"] =["has_count": "yes"];

                    maintSub["info_count"] = summary.infoCount;
                    maintSub["warning_count"] = summary.warningCount;
                    maintSub["error_count"] = summary.errorCount;
                }

                res ~= mustache.renderString (content, intCtx);
            }

            return res;
        };

        renderPage ("issues_index", hindexExportName, summaryCtx);
    }

    private DataSummary preprocessInformation (string suiteName, string section, Package[] pkgs)
    {
        DataSummary dsum;

        logInfo ("Collecting data about hints and available metainfo for %s/%s", suiteName, section);
        auto hintstore = HintsStorage.get ();

        foreach (pkg; pkgs) {
            auto pkid = Package.getId (pkg);

            auto hintsData = dcache.getHints (pkid);
            if (hintsData is null)
                continue;
            auto hintsCpts = parseJSON (hintsData);
            hintsCpts = hintsCpts["hints"];

            PkgSummary pkgsummary;
            pkgsummary.pkgname = pkg.name;

            foreach (cid; hintsCpts.object.byKey ()) {
                auto jhints = hintsCpts[cid];
                HintEntry he;
                he.identifier = cid;

                foreach (jhint; jhints.array) {
                    auto tag = jhint["tag"].str;
                    auto hdef = hintstore.getHintDef (tag);
                    if (hdef.tag is null) {
                        logError ("Encountered invalid tag '%s' in component '%s' of package '%s'", tag, cid, pkid);
                        continue;
                    }

                    // render the full message using the static template and data from the hint
                    auto context = new Mustache.Context;
                    foreach (var; jhint["vars"].object.byKey ()) {
                        context[var] = jhint["vars"][var];
                    }
                    auto msg = mustache.renderString (hdef.text, context);

                    // add the new hint to the right category
                    auto severity = hintstore.getSeverity (tag);
                    if (severity == HintSeverity.INFO) {
                        he.infos ~= HintTag (tag, msg);
                        pkgsummary.infoCount++;
                    } else if (severity == HintSeverity.WARNING) {
                        he.warnings ~= HintTag (tag, msg);
                        pkgsummary.warningCount++;
                    } else {
                        he.errors ~= HintTag (tag, msg);
                        pkgsummary.errorCount++;
                    }
                }

                dsum.hintEntries[pkg.name][he.identifier] = he;
            }

            dsum.pkgSummaries[pkg.maintainer] ~= pkgsummary;
            dsum.totalInfos += pkgsummary.infoCount;
            dsum.totalWarnings += pkgsummary.warningCount;
            dsum.totalErrors += pkgsummary.errorCount;
        }

        return dsum;
    }

    private void saveStatistics (string suiteName, string section, DataSummary dsum)
    {
        auto stat = JSONValue (["suite": JSONValue (suiteName),
                                "section": JSONValue (section),
                                "totalInfos": JSONValue (dsum.totalInfos),
                                "totalWarnings": JSONValue (dsum.totalWarnings),
                                "totalErrors": JSONValue (dsum.totalErrors),
                                "totalMetadata": JSONValue (42)]);
        dcache.addStatistics (toJSON (&stat));
    }

    void exportStatistics ()
    {
        logInfo ("Exporting statistical data.");

        // return all statistics we have from the database
        auto statsCollection = dcache.getStatistics ();

        auto emptyJsonObject ()
        {
            auto jobj = JSONValue (["null": 0]);
            jobj.object.remove ("null");
            return jobj;
        }

        auto emptyJsonArray ()
        {
            auto jarr = JSONValue ([0, 0]);
            jarr.array = [];
            return jarr;
        }

        // create JSON for use with e.g. Rickshaw graph
        auto smap = emptyJsonObject ();

        foreach (timestamp; statsCollection.byKey ()) {
            auto jdata = statsCollection[timestamp];
            auto jvals = parseJSON (jdata);

            auto suite = jvals["suite"].str;
            auto section = jvals["section"].str;
            if (suite !in smap)
                smap.object[suite] = emptyJsonObject ();
            if (section !in smap[suite]) {
                smap[suite].object[section] = emptyJsonObject ();
                auto sso = smap[suite][section].object;
                sso["errors"] = emptyJsonArray ();
                sso["warnings"] = emptyJsonArray ();
                sso["infos"] = emptyJsonArray ();
                sso["metadata"] = emptyJsonArray ();
            }
            auto suiteSectionObj = smap[suite][section].object;

            auto pointErr = JSONValue (["x": JSONValue (timestamp), "y": JSONValue (jvals["totalErrors"])]);
            suiteSectionObj["errors"].array ~= pointErr;

            auto pointWarn = JSONValue (["x": JSONValue (timestamp), "y": JSONValue (jvals["totalWarnings"])]);
            suiteSectionObj["warnings"].array ~= pointWarn;

            auto pointInfo = JSONValue (["x": JSONValue (timestamp), "y": JSONValue (jvals["totalInfos"])]);
            suiteSectionObj["infos"].array ~= pointInfo;

            auto pointMD = JSONValue (["x": JSONValue (timestamp), "y": JSONValue (jvals["totalMetadata"])]);
            suiteSectionObj["metadata"].array ~= pointMD;
        }

        bool compareJData (JSONValue x, JSONValue y) @trusted
        {
            return x["x"].integer < y["x"].integer;
        }

        // ensure our data is sorted ascending by X
        foreach (suite; smap.object.byKey ()) {
            foreach (section; smap[suite].object.byKey ()) {
                auto sso = smap[suite][section].object;

                std.algorithm.sort!(compareJData) (sso["errors"].array);
                std.algorithm.sort!(compareJData) (sso["warnings"].array);
                std.algorithm.sort!(compareJData) (sso["infos"].array);
                std.algorithm.sort!(compareJData) (sso["metadata"].array);
            }
        }

        auto fname = buildPath (htmlExportDir, "statistics.json");
        mkdirRecurse (dirName (fname));

        auto sf = File (fname, "w");
        sf.writeln (toJSON (&smap, true));
        sf.flush ();
        sf.close ();
    }

    void processFor (string suiteName, string section, Package[] pkgs)
    {
        auto dsum = preprocessInformation (suiteName, section, pkgs);
        saveStatistics (suiteName, section, dsum);
        renderPagesFor (suiteName, section, dsum);
    }

    void renderMainIndex ()
    {
        logInfo ("Rendering HTML main index.");
        // render main overview
        auto context = new Mustache.Context;
        foreach (suite; conf.suites) {
            auto sub = context.addSubContext("suites");
            sub["suite"] = suite.name;
        }

        renderPage ("main", "index", context);
    }
}

unittest
{
    writeln ("TEST: ", "Report Generator");

    //auto rg = new ReportGenerator (null);
    //rg.renderIndices ();
}
