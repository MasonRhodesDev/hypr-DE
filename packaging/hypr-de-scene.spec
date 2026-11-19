Name:           hypr-de-scene
Version:        0.2.39
Release:        1%{?dist}
Summary:        Hyprland plugin that keeps the boot scene on screen from a session's first frame

License:        MIT
URL:            https://github.com/MasonRhodesDev/hypr-DE
Source0:        %{url}/archive/v%{version}/hypr-DE-%{version}.tar.gz

BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  hyprland-devel
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  bubblewrap

Requires:       hyprland
Recommends:     desktop-boot

%description
Draws the boot scene's ground and logo into every output from Hyprland's
first commit and keeps them there until desktop-boot's login splash covers
that output, or for five seconds at most, so a login never shows an
unrendered or empty frame. Opt in by adding
  hl.plugin.load("%{_prefix}/lib/hypr-de/hypr-de-scene.so")
to ~/.config/hypr/local.lua. Without desktop-boot's scene files the plugin
stays idle. It works only in the Hyprland build it was compiled against.
After a Hyprland upgrade it loads idle, with nothing on screen, until this
package is rebuilt, and the journal tag hypr-de-scene says so. Hyprland
loads a small loader that needs nothing from Hyprland, and the loader opens
the plugin itself, so an upgrade that removes a symbol the plugin needs
also leaves it idle rather than failing the load.

%prep
%autosetup -n hypr-DE-%{version}

%build
%cmake -S plugins/hypr-de-scene
%cmake_build

%check
export HYPR_DE_ALLOW_UNSEALED=1
./tests/scene-geometry.sh
./tests/scene-plugin-build.sh

%install
%cmake_install

%files
%license LICENSE
%dir %{_prefix}/lib/hypr-de
%{_prefix}/lib/hypr-de/hypr-de-scene.so
%{_prefix}/lib/hypr-de/hypr-de-scene-impl.so

%changelog
* Thu Nov 19 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.39-1
- Initial package
