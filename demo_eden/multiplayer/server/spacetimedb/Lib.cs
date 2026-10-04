using SpacetimeDB;

// Eden multiplayer: who is on the planet and where, and the terrain edits everyone has made. Positions are
// planet-relative metres (the planet's centre is the origin), so they mean the same thing on every client.
public static partial class Module
{
    [Table(Accessor = "player", Public = true)]
    public partial struct Player
    {
        [PrimaryKey]
        public Identity identity;
        public string name;
        public bool online;
        public double x;
        public double y;
        public double z;
        // Facing, radians from planet north
        public float yaw;
        // Animation state as the client shows it: idle, walk, run, crouch_idle, crouch_walk, jump, fall, swim, tread
        public string state;
        public float speed;
    }

    [Table(Accessor = "voxel_edit", Public = true)]
    public partial struct VoxelEdit
    {
        [PrimaryKey, AutoInc]
        public ulong id;
        public Identity author;
        public double x;
        public double y;
        public double z;
        public float radius;
        // 0 dig (remove a sphere), 1 place (add a sphere painted with `material`, a V4 MAT_* index), 2 fell / break
        // the foliage there (trees, boulders)
        public byte mode;
        public byte material;
        public Timestamp at;
    }

    // A building piece (the game's EdenBuildPieces kinds): planet-relative position and rotation
    [Table(Accessor = "build_piece", Public = true)]
    public partial struct BuildPiece
    {
        [PrimaryKey, AutoInc]
        public ulong id;
        public string kind;
        public double x;
        public double y;
        public double z;
        public float qx;
        public float qy;
        public float qz;
        public float qw;
        public Identity author;
    }

    // The world's calendar clock (one row, id 0): the calendar's day count at `set_at`, and how many days pass per
    // real second (0 = paused). Clients work out the time now from it, so everyone shares one date and season.
    [Table(Accessor = "world_clock", Public = true)]
    public partial struct WorldClock
    {
        [PrimaryKey]
        public uint id;
        public double days;
        public Timestamp set_at;
        public double days_per_second;
    }

    // What this world is (one row, id 0): its name, the planet generator's seed, its settings (the game's
    // EdenWorldSettings as JSON: template, temperature, rainfall; one text column so new options need no schema
    // change) and who created it. Set once by create_world, right after the host publishes the database.
    [Table(Accessor = "world_meta", Public = true)]
    public partial struct WorldMeta
    {
        [PrimaryKey]
        public uint id;
        public string name;
        public long seed;
        public Identity owner;
        public Timestamp created_at;
        public string settings;
    }

    // A player's inventory: item counts in the game's EdenMiner.ITEMS order. Kept between sessions like the
    // player row (where they are), so rejoining puts them back as they left.
    [Table(Accessor = "player_inventory", Public = true)]
    public partial struct PlayerInventory
    {
        [PrimaryKey]
        public Identity identity;
        public System.Collections.Generic.List<int> counts;
    }

    // The server's world directory. Only used in the database named "eden-lobby" (the same module), which the game's
    // world list reads on every server it knows: each hosted world lists itself there.
    [Table(Accessor = "world_listing", Public = true)]
    public partial struct WorldListing
    {
        [PrimaryKey]
        public string database;
        public string name;
        public long seed;
        public string host_name;
        public Identity lister;
        public Timestamp listed_at;
    }

    // The world's weather (one row, id 0): the host's EdenAmbience.get_weather_state() (weather_override, then the
    // roaming storm cells). Only the world's owner sends it; everyone else's weather follows.
    [Table(Accessor = "world_weather", Public = true)]
    public partial struct WorldWeather
    {
        [PrimaryKey]
        public uint id;
        public System.Collections.Generic.List<float> state;
    }

    // Footprints in the snow: a stretch of someone's path (planet-relative x y z per print, ~0.4 m apart) and when it
    // was walked. Kept for TrailLifetime so players arriving later still see (and can follow) them, fading by their
    // age; the game's EdenAmbience.snow_trail_lifetime must match.
    [Table(Accessor = "snow_trail", Public = true)]
    public partial struct SnowTrail
    {
        [PrimaryKey, AutoInc]
        public ulong id;
        public Identity author;
        public Timestamp at;
        public System.Collections.Generic.List<float> points;
    }

    // Text chat: the last MaxChatKept messages. kind 0 is a said line, 1 an emote (/me), 2 an announcement (a
    // player's own command output stays on their client). `name` is the sender's name when they spoke.
    [Table(Accessor = "chat_message", Public = true)]
    public partial struct ChatMessage
    {
        [PrimaryKey, AutoInc]
        public ulong id;
        public Identity sender;
        public string name;
        public string text;
        public byte kind;
        public Timestamp at;
    }

    // When each player last spoke (private), for the rate limit
    [Table(Accessor = "chat_cooldown")]
    public partial struct ChatCooldown
    {
        [PrimaryKey]
        public Identity identity;
        public long last_micros;
    }

    const int MaxChatText = 500;
    const int MaxChatKept = 100;
    const long ChatIntervalMicros = 300_000;

    [Reducer]
    public static void send_chat(ReducerContext ctx, string text, byte kind)
    {
        var p = ctx.Db.player.identity.Find(ctx.Sender) ?? throw new System.Exception("Join with set_name first");
        text = text.Trim();
        if (text.Length == 0 || text.Length > MaxChatText)
        {
            throw new System.Exception($"Messages are 1-{MaxChatText} characters");
        }
        foreach (var c in text)
        {
            if (char.IsControl(c))
            {
                throw new System.Exception("Messages are plain text");
            }
        }
        if (kind > 1)
        {
            throw new System.Exception("Bad message kind");
        }
        var now = ctx.Timestamp.MicrosecondsSinceUnixEpoch;
        if (ctx.Db.chat_cooldown.identity.Find(ctx.Sender) is ChatCooldown cd)
        {
            if (now - cd.last_micros < ChatIntervalMicros)
            {
                throw new System.Exception("Slow down");
            }
            ctx.Db.chat_cooldown.identity.Update(cd with { last_micros = now });
        }
        else
        {
            ctx.Db.chat_cooldown.Insert(new ChatCooldown { identity = ctx.Sender, last_micros = now });
        }
        var row = ctx.Db.chat_message.Insert(new ChatMessage { sender = ctx.Sender, name = p.name, text = text, kind = kind, at = ctx.Timestamp });
        if (row.id > MaxChatKept)
        {
            var oldest = row.id - MaxChatKept;
            foreach (var m in System.Linq.Enumerable.ToList(ctx.Db.chat_message.Iter()))
            {
                if (m.id <= oldest)
                {
                    ctx.Db.chat_message.id.Delete(m.id);
                }
            }
        }
    }

    const long TrailLifetimeMicros = 600L * 1000000L;
    const int MaxTrailPoints = 64;

    [Reducer]
    public static void add_snow_trail(ReducerContext ctx, System.Collections.Generic.List<float> points)
    {
        if (points.Count == 0 || points.Count % 3 != 0 || points.Count > MaxTrailPoints * 3)
        {
            throw new System.Exception("Bad trail");
        }
        for (int i = 0; i < points.Count; i += 3)
        {
            CheckReach(ctx, points[i], points[i + 1], points[i + 2]);
        }
        ctx.Db.snow_trail.Insert(new SnowTrail { author = ctx.Sender, at = ctx.Timestamp, points = points });
        // Faded ones go
        var cutoff = ctx.Timestamp.MicrosecondsSinceUnixEpoch - TrailLifetimeMicros;
        foreach (var t in System.Linq.Enumerable.ToList(ctx.Db.snow_trail.Iter()))
        {
            if (t.at.MicrosecondsSinceUnixEpoch < cutoff)
            {
                ctx.Db.snow_trail.id.Delete(t.id);
            }
        }
    }

    [Reducer]
    public static void set_weather(ReducerContext ctx, System.Collections.Generic.List<float> state)
    {
        if (ctx.Db.world_meta.id.Find(0) is WorldMeta meta && meta.owner != ctx.Sender)
        {
            throw new System.Exception("Only the host sets the weather");
        }
        if (state.Count > 4096 || state.Exists(f => !float.IsFinite(f)))
        {
            throw new System.Exception("Bad weather");
        }
        var row = new WorldWeather { id = 0, state = state };
        if (ctx.Db.world_weather.id.Find(0) is null)
        {
            ctx.Db.world_weather.Insert(row);
        }
        else
        {
            ctx.Db.world_weather.id.Update(row);
        }
    }

    // Players connected when the server was stopped (the game kills it at quit, or it crashed) never got
    // ClientDisconnected, so their rows still say online. The host calls this right after starting the server, when
    // nobody can be connected yet.
    [Reducer]
    public static void all_offline(ReducerContext ctx)
    {
        if (ctx.Db.world_meta.id.Find(0) is WorldMeta meta && meta.owner != ctx.Sender)
        {
            throw new System.Exception("Only the host");
        }
        foreach (var p in System.Linq.Enumerable.ToList(ctx.Db.player.Iter()))
        {
            if (p.online)
            {
                ctx.Db.player.identity.Update(p with { online = false });
            }
        }
    }

    [Reducer(ReducerKind.Init)]
    public static void Init(ReducerContext ctx)
    {
        // Month 4, day 1, 09:00 (4-day months): the northern summer solstice, a morning
        ctx.Db.world_clock.Insert(new WorldClock { id = 0, days = 12.375, set_at = ctx.Timestamp, days_per_second = 1.0 / (24.0 * 60.0) });
    }

    // Sets the world's date and time and how fast it runs (the calendar panel's speed and skip buttons)
    [Reducer]
    public static void set_clock(ReducerContext ctx, double days, double days_per_second)
    {
        if (ctx.Db.player.identity.Find(ctx.Sender) is null)
        {
            throw new System.Exception("Join with set_name first");
        }
        if (!double.IsFinite(days) || days < 0 || !double.IsFinite(days_per_second) || days_per_second < 0 || days_per_second > 1.0)
        {
            throw new System.Exception("Bad clock");
        }
        var row = new WorldClock { id = 0, days = days, set_at = ctx.Timestamp, days_per_second = days_per_second };
        if (ctx.Db.world_clock.id.Find(0) is null)
        {
            ctx.Db.world_clock.Insert(row);
        }
        else
        {
            ctx.Db.world_clock.id.Update(row);
        }
    }

    static readonly string[] PieceKinds = { "wood_floor", "wood_wall", "wood_half_wall", "wood_beam", "wood_pole", "wood_roof",
        "wood_stairs", "stone_floor", "stone_wall", "stone_pillar" };

    const int MaxName = 24;
    const float MaxRadius = 3.0f;
    // How far from where the server last saw a player they may edit (the client's reach is 6 m)
    const double MaxEditReach = 12.0;
    static readonly string[] States = { "idle", "walk", "run", "crouch_idle", "crouch_walk", "jump", "fall", "swim", "tread" };

    // A player row exists once a client joins with set_name (the game does on connecting). Other connections,
    // such as `spacetime sql` from the CLI, don't show up as players.
    [Reducer(ReducerKind.ClientConnected)]
    public static void ClientConnected(ReducerContext ctx)
    {
        if (ctx.Db.player.identity.Find(ctx.Sender) is Player p)
        {
            p.online = true;
            ctx.Db.player.identity.Update(p);
        }
    }

    [Reducer(ReducerKind.ClientDisconnected)]
    public static void ClientDisconnected(ReducerContext ctx)
    {
        if (ctx.Db.player.identity.Find(ctx.Sender) is Player p)
        {
            p.online = false;
            ctx.Db.player.identity.Update(p);
        }
    }

    [Reducer]
    public static void set_name(ReducerContext ctx, string name)
    {
        name = name.Trim();
        if (name.Length == 0 || name.Length > MaxName)
        {
            throw new System.Exception($"Names are 1-{MaxName} characters");
        }
        if (ctx.Db.player.identity.Find(ctx.Sender) is Player p)
        {
            p.name = name;
            p.online = true;
            ctx.Db.player.identity.Update(p);
        }
        else
        {
            ctx.Db.player.Insert(new Player { identity = ctx.Sender, name = name, online = true, state = "idle" });
        }
    }

    [Reducer]
    public static void update_player(ReducerContext ctx, double x, double y, double z, float yaw, string state, float speed)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(z) || !float.IsFinite(yaw) || !float.IsFinite(speed))
        {
            throw new System.Exception("Bad position");
        }
        var p = ctx.Db.player.identity.Find(ctx.Sender) ?? throw new System.Exception("Join with set_name first");
        p.x = x;
        p.y = y;
        p.z = z;
        p.yaw = yaw;
        p.state = System.Array.IndexOf(States, state) >= 0 ? state : "idle";
        p.speed = System.Math.Clamp(speed, 0f, 20f);
        ctx.Db.player.identity.Update(p);
    }

    static void CheckReach(ReducerContext ctx, double x, double y, double z)
    {
        var p = ctx.Db.player.identity.Find(ctx.Sender) ?? throw new System.Exception("Join with set_name first");
        var dx = x - p.x;
        var dy = y - p.y;
        var dz = z - p.z;
        if (!double.IsFinite(x + y + z) || dx * dx + dy * dy + dz * dz > MaxEditReach * MaxEditReach)
        {
            throw new System.Exception("Out of reach");
        }
    }

    [Reducer]
    public static void place_piece(ReducerContext ctx, string kind, double x, double y, double z, float qx, float qy, float qz, float qw)
    {
        CheckReach(ctx, x, y, z);
        if (System.Array.IndexOf(PieceKinds, kind) < 0 || !float.IsFinite(qx + qy + qz + qw))
        {
            throw new System.Exception("Bad piece");
        }
        ctx.Db.build_piece.Insert(new BuildPiece { kind = kind, x = x, y = y, z = z, qx = qx, qy = qy, qz = qz, qw = qw, author = ctx.Sender });
    }

    [Reducer]
    public static void remove_piece(ReducerContext ctx, ulong id)
    {
        var piece = ctx.Db.build_piece.id.Find(id) ?? throw new System.Exception("No such piece");
        CheckReach(ctx, piece.x, piece.y, piece.z);
        ctx.Db.build_piece.id.Delete(id);
    }

    // Names the world and fixes its seed and settings. Only the first call counts (the host's, right after publishing).
    [Reducer]
    public static void create_world(ReducerContext ctx, string name, long seed, string settings)
    {
        if (ctx.Db.world_meta.id.Find(0) is not null)
        {
            return;
        }
        name = name.Trim();
        if (name.Length == 0 || name.Length > 40)
        {
            throw new System.Exception("World names are 1-40 characters");
        }
        if (settings.Length > 1024)
        {
            throw new System.Exception("World settings are at most 1024 characters");
        }
        ctx.Db.world_meta.Insert(new WorldMeta { id = 0, name = name, seed = seed, owner = ctx.Sender, created_at = ctx.Timestamp, settings = settings });
    }

    const int MaxItems = 16;
    const int MaxCount = 100000;

    [Reducer]
    public static void set_inventory(ReducerContext ctx, System.Collections.Generic.List<int> counts)
    {
        if (ctx.Db.player.identity.Find(ctx.Sender) is null)
        {
            throw new System.Exception("Join with set_name first");
        }
        if (counts.Count > MaxItems || counts.Exists(c => c < 0 || c > MaxCount))
        {
            throw new System.Exception("Bad inventory");
        }
        var row = new PlayerInventory { identity = ctx.Sender, counts = counts };
        if (ctx.Db.player_inventory.identity.Find(ctx.Sender) is null)
        {
            ctx.Db.player_inventory.Insert(row);
        }
        else
        {
            ctx.Db.player_inventory.identity.Update(row);
        }
    }

    // Lists (or relists) a hosted world in this server's directory. A listing belongs to whoever made it: only they
    // can change or remove it.
    [Reducer]
    public static void list_world(ReducerContext ctx, string database, string name, long seed, string host_name)
    {
        if (database.Length == 0 || database.Length > 64 || name.Length == 0 || name.Length > 40 || host_name.Length > MaxName)
        {
            throw new System.Exception("Bad listing");
        }
        var row = new WorldListing { database = database, name = name, seed = seed, host_name = host_name, lister = ctx.Sender, listed_at = ctx.Timestamp };
        if (ctx.Db.world_listing.database.Find(database) is WorldListing old)
        {
            if (old.lister != ctx.Sender)
            {
                throw new System.Exception("Listed by someone else");
            }
            ctx.Db.world_listing.database.Update(row);
        }
        else
        {
            ctx.Db.world_listing.Insert(row);
        }
    }

    [Reducer]
    public static void unlist_world(ReducerContext ctx, string database)
    {
        var old = ctx.Db.world_listing.database.Find(database) ?? throw new System.Exception("Not listed");
        if (old.lister != ctx.Sender)
        {
            throw new System.Exception("Listed by someone else");
        }
        ctx.Db.world_listing.database.Delete(database);
    }

    [Reducer]
    public static void add_voxel_edit(ReducerContext ctx, double x, double y, double z, float radius, byte mode, byte material)
    {
        var p = ctx.Db.player.identity.Find(ctx.Sender) ?? throw new System.Exception("Join with set_name first");
        var dx = x - p.x;
        var dy = y - p.y;
        var dz = z - p.z;
        if (!double.IsFinite(x + y + z) || dx * dx + dy * dy + dz * dz > MaxEditReach * MaxEditReach)
        {
            throw new System.Exception("Out of reach");
        }
        if (mode > 6 || material > 6 || !(radius > 0.1f && radius <= MaxRadius))
        {
            throw new System.Exception("Bad edit");
        }
        ctx.Db.voxel_edit.Insert(new VoxelEdit
        {
            author = ctx.Sender, x = x, y = y, z = z, radius = radius, mode = mode, material = material, at = ctx.Timestamp,
        });
    }
}
