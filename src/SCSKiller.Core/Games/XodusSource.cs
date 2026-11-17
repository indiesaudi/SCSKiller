using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SCSKiller.Core.Games;

/// <summary>The Microsoft Store PC games Nexus Launcher (Xodus Nexus, github.com/domsvoboda/xodus-nexus) installs and runs
/// on its own Proton build: launcher-state.json in its profile ($XDG_CONFIG_HOME/xodus-nexus), each game's folder, launch
/// exe, installed version, runtime and launch options, and the launcher's settings (its runtime folder, whose parent is its
/// data folder, its default runtime and its shader cache limit). Id "xodus:&lt;id&gt;", the launcher's own game id, Store.Other,
/// told apart by its id, as a game of this PC's own: its exe must resolve to a game folder of its own
/// (<see cref="ManualSource.Resolve"/>, <see cref="ManualSource.RootProblem"/>) outside the system's, Steam's and Wine's
/// folders (<see cref="SteamShortcutSource.StartProblem"/>). Only read: the launcher writes its files at each change.</summary>
public sealed class XodusSource(string? config = null, string? steamRoot = null) : IGameSource, ILeavesOut
{
    public Store Store => Store.Other;

    public const string IdPrefix = "xodus:", Name = "Xodus Nexus";

    /// <summary>A game left out, and why.</summary>
    public IProgress<string>? Log { get; set; }

    public Func<string, bool> LeftOut { get; set; } = _ => false;

    public static bool Is(string gameId) => gameId.StartsWith(IdPrefix, StringComparison.Ordinal) && gameId.Length > IdPrefix.Length;

    /// <summary>The launcher's profile folder, as Electron names it for the app "xodus-nexus": $XDG_CONFIG_HOME/xodus-nexus,
    /// else ~/.config/xodus-nexus.</summary>
    public static string Config(string? home = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var config = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } x && Path.IsPathRooted(x) ? x : Path.Combine(home, ".config");
        return Path.Combine(config, "xodus-nexus");
    }

    public IReadOnlyList<Game> Discover()
    {
        var games = new List<Game>();
        var root = steamRoot ?? SteamSource.Root();
        var state = State.Read(config ?? Config());
        foreach (var e in state?.Games ?? [])
            if (e.InstallState is not ("ready" or "imported")) Log?.Report($"{Name}: {e.Title} isn't listed: it isn't fully installed");
            else if (e.Exe is not { } exe) Log?.Report($"{Name}: {e.Title} isn't listed: {Name} names no launch exe for it");
            else if (LeftOut(exe)) continue;
            else if (GameOf(e, exe, root, out var why) is { } g) games.Add(g);
            else Log?.Report($"{Name}: {e.Title} isn't listed: {why}");
        return games.DistinctBy(g => g.Id).ToList();
    }

    /// <summary>What the launcher's own desktop and Steam shortcuts for the game run: its launch-game script in the profile,
    /// with the game's id. Null when the launcher doesn't list the game or the script isn't there.</summary>
    public static System.Diagnostics.ProcessStartInfo? Launch(Game g, string? config = null)
    {
        if (!Is(g.Id)) return null;
        config ??= Config();
        var script = Path.Combine(config, "shortcuts", "launch-game");
        var id = g.Id[IdPrefix.Length..];
        try { return File.Exists(script) && State.Read(config)?.Games.Any(e => e.Id == id) == true ? new("/bin/sh", [script, id]) : null; }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>The Steam shortcut a game of the launcher is started from in Steam: the one the launcher's "Add to Steam" made
    /// for the game, which runs its launch-game script with the game's id (as the shortcut's exe or in its launch options),
    /// else the launcher's own, which runs its launch-nexus script (the game is then started with Play inside it). The game
    /// inherits that shortcut's environment through the launcher, so what a wrapper in its launch options sets (Armada's
    /// Turnip build, <see cref="ArmadaLaunch"/>) is the game's too. Null: neither is there.</summary>
    public static SteamShortcut? Shortcut(string gameId, string steamRoot, string? config = null)
    {
        if (!Is(gameId)) return null;
        config ??= Config();
        var id = gameId[IdPrefix.Length..];
        string game = Path.Combine(config, "shortcuts", "launch-game"), launcher = Path.Combine(config, "shortcuts", "launch-nexus");
        var word = new Regex($"(?<![A-Za-z0-9_-]){Regex.Escape(id)}(?![A-Za-z0-9_-])");
        List<SteamShortcut> all;
        try { all = SteamShortcuts.All(steamRoot); }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
        bool Runs(SteamShortcut s, string script) => s.Exe.Contains(script, StringComparison.Ordinal) || s.LaunchOptions.Contains(script, StringComparison.Ordinal);
        return all.FirstOrDefault(s => Runs(s, game) && word.IsMatch(s.LaunchOptions)) ?? all.FirstOrDefault(s => Runs(s, launcher));
    }

    /// <summary>The game at its folder and the exe its package names (its MicrosoftGame.config's, as the launcher's state
    /// gives it), not resolved as an exe the user picks is (<see cref="ManualSource.Resolve"/>): a Microsoft Store package
    /// keeps its exes encrypted on disk, and the launcher runs a decrypted copy from a launch view it makes at each start
    /// (.xodus-chain-* beside the games), so no exe of the folder can be read. Its folder must be one game's own
    /// (<see cref="ManualSource.RootProblem"/>), outside the system's, Steam's and Wine's (<see cref="SteamShortcutSource.StartProblem"/>).</summary>
    static Game? GameOf(Entry e, string exe, string steamRoot, out string? why)
    {
        why = null;
        try
        {
            if (!exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                why = $"{Path.GetFileName(exe)} isn't a Windows program";
            else if (!File.Exists(exe))
                why = $"{exe} isn't there";
            else
                why = SteamShortcutSource.StartProblem(steamRoot, e.Path) ?? SteamShortcutSource.StartProblem(steamRoot, exe) ?? ManualSource.RootProblem(e.Path, exe, []);
            return why == null ? new Game(IdPrefix + e.Id, e.Title, Store.Other, Path.TrimEndingDirectorySeparator(e.Path), exe, e.Version) : null;
        }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { why = x.Message; }
        return null;
    }

    /// <summary>Where the launcher runs a game of its own, read from its files now (its runtime_prefix_binding.ts and
    /// proton.ts): on its default runtime the Proton build its settings name (a build of its own runtimes folder: the one
    /// runtimes/current.json makes active), in &lt;data&gt;/compatdata/&lt;id&gt;; on a runtime family of its own ("nexus",
    /// "nexus-cachyos") that family's current build, in &lt;data&gt;/runtime-prefixes/&lt;family&gt;/&lt;build id, or prefixes&gt;/&lt;id&gt;/compatdata.
    /// Its Proton runs on the host, outside any Steam Linux Runtime, with the launcher's Steam folder ~/.steam/root, the
    /// shader cache folders of the prefix, and UMU_ID and UMU_USE_STEAM, which pick its script's plain Wine route (<see cref="Env"/>).
    /// Null with the reason when it can't be told or the runtime is no Proton; null with no reason for a game of no Xodus Nexus.</summary>
    public static LauncherPrefix? PrefixOf(Game g, out string? why, string? config = null, string? home = null)
    {
        why = null;
        if (!Is(g.Id)) return null;
        var id = g.Id[IdPrefix.Length..];
        try
        {
            if (State.Read(config ?? Config(home)) is not { } state)
            {
                why = $"{Name}'s launcher-state.json couldn't be read";
                return null;
            }
            if (state.Games.FirstOrDefault(x => x.Id == id) is not { } e)
            {
                why = $"{Name} doesn't list it anymore";
                return null;
            }
            if (state.RuntimeRoot is not { } runtimes || !Path.IsPathFullyQualified(runtimes))
            {
                why = $"{Name} names no runtime folder: install its runtime in its settings";
                return null;
            }
            var data = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(runtimes))!;
            string proton, compat;
            if (e.Runtime is null or "default")
            {
                if (state.Wine(runtimes) is not { } wine)
                {
                    why = $"{Name} names no runtime for it: pick one in its settings";
                    return null;
                }
                proton = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(wine)!, "..", ".."));
                compat = Path.Combine(data, "compatdata", id);
            }
            else if (e.Runtime is "nexus" or "nexus-cachyos")
            {
                if (!e.SeparatePrefix)
                {
                    why = $"{Name} runs it on its {e.Runtime} runtime without a prefix of its own, which it refuses";
                    return null;
                }
                if (Family(runtimes, e.Runtime) is not { } build)
                {
                    why = $"its {e.Runtime} runtime isn't installed where {Name} looks for it";
                    return null;
                }
                proton = build;
                compat = Path.Combine(data, "runtime-prefixes", e.Runtime, e.PrefixBuild ?? "prefixes", id, "compatdata");
            }
            else
            {
                why = $"{Name} runs it on a runtime SCSKiller doesn't know ({e.Runtime})";
                return null;
            }
            if (!File.Exists(Path.Combine(proton, "proton")))
            {
                why = $"{Name} runs it on Wine ({proton}), not on a Proton build";
                return null;
            }
            return new LauncherPrefix(Name, compat, proton, true, null, Env(compat, e.LaunchOptions, state.ShaderCacheGiB), Umu: false, Args: e.Args,
                Host: true, SteamRoot: Path.Combine(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".steam", "root"),
                Run: [("UMU_ID", "xodus-nexus"), ("UMU_USE_STEAM", "0")]);
        }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            why = $"{Name}'s files couldn't be read: {x.Message}";
            return null;
        }
    }

    /// <summary>The variables a game starts with: its launch options' leading NAME=value words (a game's own setting wins),
    /// then the prefix's shader cache folders unless those set them: vkd3d-proton's, NVIDIA's with its size, Mesa's with
    /// MESA_SHADER_CACHE_MAX_SIZE the launcher's limit (proton.ts, shared/shader-cache.ts).</summary>
    internal static List<(string Name, string Value)> Env(string compat, string? options, double cacheGiB)
    {
        var env = Assignments(options);
        bool Set(string name) => env.Any(v => v.Name == name);
        var cache = Path.Combine(compat, "shadercache");
        var bytes = (cacheGiB * 1024 * 1024 * 1024).ToString("0", CultureInfo.InvariantCulture);
        var mesaSize = cacheGiB == Math.Floor(cacheGiB) ? $"{cacheGiB.ToString(CultureInfo.InvariantCulture)}G" : $"{(cacheGiB * 1024).ToString(CultureInfo.InvariantCulture)}M";
        if (!Set("VKD3D_SHADER_CACHE_PATH")) env.Add(("VKD3D_SHADER_CACHE_PATH", Path.Combine(cache, "vkd3d-proton")));
        if (!Set("__GL_SHADER_DISK_CACHE_PATH"))
        {
            env.Add(("__GL_SHADER_DISK_CACHE_PATH", Path.Combine(cache, "nvidia")));
            if (!Set("__GL_SHADER_DISK_CACHE")) env.Add(("__GL_SHADER_DISK_CACHE", "1"));
            if (!Set("__GL_SHADER_DISK_CACHE_SIZE")) env.Add(("__GL_SHADER_DISK_CACHE_SIZE", bytes));
        }
        if (!Set("MESA_SHADER_CACHE_DIR"))
        {
            env.Add(("MESA_SHADER_CACHE_DIR", Path.Combine(cache, "mesa")));
            if (!Set("MESA_SHADER_CACHE_MAX_SIZE")) env.Add(("MESA_SHADER_CACHE_MAX_SIZE", mesaSize));
        }
        return env;
    }

    /// <summary>The leading NAME=value words of launch options, before %command% or the first other word, each with the value
    /// of the last word that set it (shared/launch-tools.ts parseLaunchOptions). None when the launcher would refuse them.</summary>
    internal static List<(string Name, string Value)> Assignments(string? options)
    {
        var env = new List<(string Name, string Value)>();
        foreach (var word in Words(options ?? "") ?? [])
        {
            if (Regex.Match(word, "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", RegexOptions.Singleline) is not { Success: true } m) break;
            env.RemoveAll(v => v.Name == m.Groups[1].Value);
            env.Add((m.Groups[1].Value, m.Groups[2].Value));
        }
        return env;
    }

    /// <summary>The launcher's split of launch options into words (shared/launch-tools.ts commandWords): quotes and
    /// backslashes as a shell takes them, nothing expanded. Null where it refuses them: over 2048 characters, a line break,
    /// a shell operator, an unclosed quote or a trailing backslash.</summary>
    internal static List<string>? Words(string input)
    {
        if (input.Length > 2048 || input.IndexOfAny(['\r', '\n', '\0']) >= 0) return null;
        var words = new List<string>();
        var word = new System.Text.StringBuilder();
        char quote = '\0';
        var started = false;
        for (var i = 0; i < input.Length; i++)
        {
            var c = input[i];
            if (c == '\\' && quote != '\'')
            {
                if (++i == input.Length) return null;
                word.Append(input[i]);
                started = true;
            }
            else if (quote != '\0') { if (c == quote) quote = '\0'; else word.Append(c); }
            else if (c is '"' or '\'') { quote = c; started = true; }
            else if (char.IsWhiteSpace(c)) { if (started) { words.Add(word.ToString()); word.Clear(); started = false; } }
            else if ("|&;<>()`$".Contains(c)) return null;
            else { word.Append(c); started = true; }
        }
        if (quote != '\0') return null;
        if (started) words.Add(word.ToString());
        return words;
    }

    /// <summary>A runtime family's current build folder, as its current.json names it (runtime-families.ts); null when that
    /// isn't there or isn't a Proton.</summary>
    static string? Family(string runtimes, string family)
    {
        var dir = Path.Combine(runtimes, "variants", family);
        if (HeroicSource.Json(Path.Combine(dir, "current.json")) is not { ValueKind: JsonValueKind.Object } pointer
            || HeroicSource.Str(pointer, "buildId") is not { } build || !Regex.IsMatch(build, "^[a-f0-9]{64}$")) return null;
        var root = Path.Combine(dir, "releases", build);
        return File.Exists(Path.Combine(root, "proton")) ? root : null;
    }

    internal sealed record Entry(string Id, string Title, string Path, string? Exe, string? InstallState, string? Version, string? Runtime, bool SeparatePrefix,
        string? PrefixBuild, string? LaunchOptions, string? Args);

    /// <summary>launcher-state.json: its games with an id the launcher accepts (a-z, 0-9, _ and -) and a folder, and the settings a
    /// launch reads.</summary>
    internal sealed record State(List<Entry> Games, string? RuntimeRoot, string? WinePath, double ShaderCacheGiB)
    {
        public const double DefaultCacheGiB = 4;

        public static State? Read(string config)
        {
            if (HeroicSource.Json(Path.Combine(config, "launcher-state.json")) is not { ValueKind: JsonValueKind.Object } root) return null;
            var settings = root.TryGetProperty("settings", out var s) && s.ValueKind == JsonValueKind.Object ? s : default;
            var games = new List<Entry>();
            if (root.TryGetProperty("games", out var all) && all.ValueKind == JsonValueKind.Array)
                foreach (var g in all.EnumerateArray())
                {
                    if (g.ValueKind != JsonValueKind.Object || HeroicSource.Str(g, "id") is not { } id || !Regex.IsMatch(id, "^[A-Za-z0-9_-]{1,128}$")
                        || HeroicSource.Str(g, "path") is not { Length: > 0 } path || !Path.IsPathFullyQualified(path)) continue;
                    var runtime = HeroicSource.Str(g, "runtime");
                    var options = g.TryGetProperty("launchTools", out var tools) && tools.ValueKind == JsonValueKind.Object ? HeroicSource.Str(tools, "launchOptions") : null;
                    games.Add(new(id, HeroicSource.Str(g, "title") is { Length: > 0 } t ? t : id, path, Exe(path, HeroicSource.Str(g, "executable")), HeroicSource.Str(g, "installState"),
                        HeroicSource.Str(g, "installedVersion"), runtime,
                        g.TryGetProperty("runtimeSeparatePrefix", out var sep) && sep.ValueKind == JsonValueKind.True, PrefixBuild(g, runtime),
                        options, Words(options ?? "") is { } words && words.IndexOf("%command%") is var at and >= 0 && at < words.Count - 1 ? string.Join(' ', words.Skip(at + 1)) : null));
                }
            return new(games, settings.ValueKind == JsonValueKind.Object ? HeroicSource.Str(settings, "runtimeRoot") : null,
                settings.ValueKind == JsonValueKind.Object ? HeroicSource.Str(settings, "winePath") : null,
                settings.ValueKind == JsonValueKind.Object && settings.TryGetProperty("shaderCacheLimitGiB", out var gib) && gib.ValueKind == JsonValueKind.Number
                    && gib.TryGetDouble(out var v) && v is >= 0.25 and <= 1024 ? v : DefaultCacheGiB);
        }

        /// <summary>The default runtime's wine (xodus-service.ts selectedWinePath): the settings' winePath, unless it is a build
        /// of the runtimes folder's releases, which runtimes/current.json's active build stands for.</summary>
        public string? Wine(string runtimes)
        {
            var releases = Path.Combine(runtimes, "releases");
            var active = HeroicSource.Json(Path.Combine(runtimes, "current.json")) is { ValueKind: JsonValueKind.Object } c ? HeroicSource.Str(c, "winePath") : null;
            if (WinePath is not { Length: > 0 } wine) return active;
            var relative = Path.GetRelativePath(releases, wine);
            var managed = relative != ".." && !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) && !Path.IsPathRooted(relative);
            return managed && active != null ? active : wine;
        }

        // a Windows-style relative exe ("Hibiki\Binaries\WinGDK\Hi-Fi-RUSH.exe") under the game's folder
        static string? Exe(string path, string? exe) =>
            exe is { Length: > 0 } && !Path.IsPathRooted(exe.Replace('\\', '/')) && !exe.Replace('\\', '/').Split('/').Contains("..")
                ? Path.Combine(path, exe.Replace('\\', '/')) : null;

        // runtimePrefixes[family] {layout: "build", origin: {buildId}}, else the legacy runtimeBuild's buildId: the prefix of
        // that build; {layout: "family"} or none: the family's
        static string? PrefixBuild(JsonElement g, string? runtime)
        {
            string? Build(JsonElement origin) => HeroicSource.Str(origin, "buildId") is { } b && Regex.IsMatch(b, "^[a-f0-9]{64}$") ? b : null;
            if (runtime is null or "default") return null;
            if (g.TryGetProperty("runtimePrefixes", out var anchors) && anchors.ValueKind == JsonValueKind.Object
                && anchors.TryGetProperty(runtime, out var anchor) && anchor.ValueKind == JsonValueKind.Object)
                return HeroicSource.Str(anchor, "layout") == "build" && anchor.TryGetProperty("origin", out var o) && o.ValueKind == JsonValueKind.Object ? Build(o) : null;
            return g.TryGetProperty("runtimeBuild", out var approved) && approved.ValueKind == JsonValueKind.Object ? Build(approved) : null;
        }
    }
}
