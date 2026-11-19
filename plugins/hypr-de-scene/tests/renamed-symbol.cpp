// stands in for the module after a Hyprland upgrade renamed a function it calls
class CCompositor {
  public:
    static void renamedByAnUpgrade();
};

extern "C" __attribute__((visibility("default"))) void pluginExit() {
    CCompositor::renamedByAnUpgrade();
}
