#pragma once

#include <format>
#include <string>

namespace Scene {
    void logTo(const std::string& dumpDir);
    void logLine(const std::string& line);

    template <typename... Args>
    void note(std::format_string<Args...> fmt, Args&&... args) {
        logLine(std::format(fmt, std::forward<Args>(args)...));
    }

    // CLOCK_MONOTONIC, which the kernel and the journal stamp with
    double monotonic();
}
