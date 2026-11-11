using System.Runtime.InteropServices;
using System.Text;
using CUE4Parse.Compression;
using SCSKiller.Core.App;

// The arm64 Linux build's checks. Usage: arm64-checks [--feed releases.<c>-linux-arm64.json] [--no-network]
//   or arm64-checks --armada <appid>...: the variables Armada's armada-game-launch adds for each Steam app (ArmadaLaunch), only
//   feeds   UpdateChannels / UpdateFeeds: the arm64 build follows its own -linux-arm64 feeds and takes only its own packages
//   codecs  Codecs: the arm64 Oodle build is pinned, downloaded and loaded (dlopen against this machine's glibc); no zlib-ng
// Set SCSKILLER_DATA_DIR to a scratch folder: the codecs are downloaded into its codecs/ folder.
// Exit code: the number of failed checks.

var failed = 0;
void Check(string what, bool ok, string? detail = null)
{
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {what}{(detail is null ? "" : $"  ({detail})")}");
    if (!ok) failed++;
}

string? feedFile = null;
var network = true;
List<uint>? armada = null;
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--feed" && i + 1 < args.Length) feedFile = args[++i];
    else if (args[i] == "--no-network") network = false;
    else if (args[i] == "--armada") armada = [];
    else if (armada != null && uint.TryParse(args[i], out var app)) armada.Add(app);
    else { Console.Error.WriteLine($"unknown argument: {args[i]}"); return 100; }
}
if (armada != null)
{
    foreach (var app in armada)
    {
        var vars = SCSKiller.Core.Games.ArmadaLaunch.Variables(app, []);
        Console.WriteLine($"{app}: {(vars.Count == 0 ? "(nothing: the system's Turnip)" : string.Join("  ", vars.Select(v => $"{v.Name}={v.Value}")))}");
    }
    return 0;
}
if (Environment.GetEnvironmentVariable("SCSKILLER_DATA_DIR") is null)
{
    Console.Error.WriteLine("set SCSKILLER_DATA_DIR to a scratch folder");
    return 100;
}

Console.WriteLine($"process: {RuntimeInformation.ProcessArchitecture}, OS: {RuntimeInformation.OSDescription}, .NET {Environment.Version}");
Check("process is arm64 Linux", OperatingSystem.IsLinux() && RuntimeInformation.ProcessArchitecture == Architecture.Arm64);

// feeds
var os = UpdateChannels.Os;
Check("update OS is LinuxArm64", os == FeedOs.LinuxArm64, os.ToString());
foreach (var c in UpdateChannels.All)
{
    Check($"{c}: signed feed name", UpdateChannels.Signed(c, os) == c + "-linux-arm64", UpdateChannels.Signed(c, os));
    Check($"{c}: feed name maps back", UpdateChannels.Of(c + "-linux-arm64", os) == c);
}
Check("x86-64 Linux feed isn't arm64's", UpdateChannels.Of("stable-linux", os) is null);
Check("Windows feed isn't arm64's", UpdateChannels.Of("stable", os) is null);
Check("x86-64 Linux build unchanged", UpdateChannels.Signed("stable", FeedOs.Linux) == "stable-linux" && UpdateChannels.Signed("stable", FeedOs.Windows) == "stable");

const string arm = "SCSKiller.App-1.4.7-stable-linux-arm64-full.nupkg", x64 = "SCSKiller.App-1.4.7-stable-linux-full.nupkg",
    win = "SCSKiller.App-1.4.7-stable-full.nupkg", armDelta = "SCSKiller.App-1.4.7-beta-linux-arm64-delta.nupkg";
foreach (var (file, owner) in new[] { (arm, FeedOs.LinuxArm64), (armDelta, FeedOs.LinuxArm64), (x64, FeedOs.Linux), (win, FeedOs.Windows) })
    foreach (var o in Enum.GetValues<FeedOs>())
        Check($"{o} {(o == owner ? "takes" : "refuses")} {file}", UpdateFeeds.PackageFor(o, file) == (o == owner));

byte[] Feed(string file) => Encoding.UTF8.GetBytes($$"""{"Assets":[{"PackageId":"SCSKiller.App","Version":"1.4.7","Type":"Full","FileName":"{{file}}","SHA256":"00","Size":1}]}""");
Check("release-sign: arm64 feed with an arm64 package signs", UpdateFeeds.Unsignable("stable-linux-arm64", Feed(arm)) is null);
Check("release-sign: arm64 feed with an x86-64 package refused", UpdateFeeds.Unsignable("stable-linux-arm64", Feed(x64)) is not null);
Check("release-sign: x86-64 feed with an arm64 package refused", UpdateFeeds.Unsignable("stable-linux", Feed(arm)) is not null);
Check("release-sign: Windows feed with an arm64 package refused", UpdateFeeds.Unsignable("stable", Feed(arm)) is not null);
if (feedFile != null)
{
    var bytes = File.ReadAllBytes(feedFile);
    var signed = Path.GetFileName(feedFile) is var n && n.StartsWith("releases.") && n.EndsWith(".json") ? n["releases.".Length..^".json".Length] : "";
    Check($"vpk's {Path.GetFileName(feedFile)} lists only arm64 packages", UpdateFeeds.Foreign(os, bytes) is null, UpdateFeeds.Foreign(os, bytes));
    Check($"vpk's {Path.GetFileName(feedFile)} may be signed as {signed}", UpdateFeeds.Unsignable(signed, bytes) is null, UpdateFeeds.Unsignable(signed, bytes));
}

// codecs
Check("native Oodle on (arm64 build pinned)", Codecs.NativeOodle);
Check("native zlib-ng off (none pinned for arm64)", !Codecs.NativeZlib);
Check("Oodle pin is the arm64 build", Codecs.Pinned.TryGetValue(OodleHelper.OodleFileName, out var sha) && sha.StartsWith("0fc48fdf"), OodleHelper.OodleFileName);
Check("Oodle URL is the arm64 build", Codecs.OodleUrl.EndsWith("gcc-arm64-release.zip"), Codecs.OodleUrl);
if (network)
{
    var log = new List<string>();
    Codecs.Log = new SyncLog(log.Add);
    Codecs.Load();
    Check("Oodle downloaded, verified and loaded", OodleHelper.Instance != null, log.Count > 0 ? string.Join("; ", log) : Path.Combine(Codecs.Dir, OodleHelper.OodleFileName));
    Check("zlib-ng not loaded (managed zlib)", ZlibHelper.Instance == null);
    if (OodleHelper.Instance != null) Check("no codec errors logged", log.Count == 0, string.Join("; ", log));
}
else Console.WriteLine("SKIP  Oodle download and load (--no-network)");

Console.WriteLine(failed == 0 ? "arm64-checks: all passed" : $"arm64-checks: {failed} FAILED");
return failed;

sealed class SyncLog(Action<string> add) : IProgress<string>
{
    public void Report(string value) => add(value);
}
