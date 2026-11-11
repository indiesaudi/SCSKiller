using System.Runtime.InteropServices;
using CUE4Parse.Compression;

namespace SCSKiller.Core.App;

public static partial class Codecs
{
    static readonly bool Arm64 = RuntimeInformation.ProcessArchitecture == Architecture.Arm64;

    /// <summary>The builds for this process's CPU. arm64: Oodle alone, Zlib-ng.NET publishes no arm64 libz-ng.so (zlib
    /// decodes in managed code there).</summary>
    public static readonly IReadOnlyDictionary<string, string> Pinned = Arm64
        ? new Dictionary<string, string>
        {
            ["liboodle-data-shared.so"] = "0fc48fdf23704ed185ab4294c4b503cc6c1e932bd70f5d20235e44a18ce5e8ab",   // OodleUE 2026-06-04-1357, gcc-arm64-release (glibc 2.38)
        }
        : new Dictionary<string, string>
        {
            ["liboodle-data-shared.so"] = "f21d70299bbe873f63e8aef778b30f4dee6dec1fc09140c185caf1f8d153f771",   // OodleUE 2026-06-04-1357, gcc-x64-release
            ["libz-ng.so"] = "583a6e04521b0406e2940f4ec61353f03bcf244c10f54038c352f300ab7bbb19",                // Zlib-ng.NET 1.0.0
        };

    public static readonly string OodleUrl = Arm64
        ? "https://github.com/WorkingRobot/OodleUE/releases/download/2026-06-04-1357/gcc-arm64-release.zip"
        : "https://github.com/WorkingRobot/OodleUE/releases/download/2026-06-04-1357/gcc-x64-release.zip";
    // not CUE4Parse's ZlibHelper.DOWNLOAD_URL, which is always the Windows DLL; x86-64 only (NativeZlib)
    public const string ZlibUrl = "https://github.com/NotOfficer/Zlib-ng.NET/releases/download/1.0.0/libz-ng.so.gz";

    static string OodleZipEntry => "lib/" + OodleHelper.OodleFileName;
}
