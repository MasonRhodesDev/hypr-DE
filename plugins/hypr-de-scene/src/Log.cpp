#include "Log.hpp"

#include <ctime>
#include <fstream>
#include <syslog.h>

static std::string logFile;

void               Scene::logTo(const std::string& dumpDir) {
    logFile = dumpDir.empty() ? "" : dumpDir + "/log";
}

void Scene::logLine(const std::string& line) {
    syslog(LOG_INFO, "%s", line.c_str());

    if (logFile.empty())
        return;

    std::ofstream file(logFile, std::ios::app);
    file << line << "\n";
}

double Scene::monotonic() {
    timespec now = {};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}
