-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)

local RemoteFunctions = ReplicatedStorage:FindFirstChild("RemoteFunctions") or ReplicatedStorage
local PlaceUnit = RemoteFunctions:FindFirstChild("PlaceUnit")
local SellUnit = RemoteFunctions:FindFirstChild("SellUnit")
local PlaceDifficultyVote = RemoteFunctions:FindFirstChild("PlaceDifficultyVote")
local StartDifficultyVote = (ReplicatedStorage:FindFirstChild("RemoteEvents") and ReplicatedStorage.RemoteEvents:FindFirstChild("StartDifficultyVote")) or ReplicatedStorage:FindFirstChild("StartDifficultyVote")
local SetUnitEquipped = RemoteFunctions:FindFirstChild("SetUnitEquipped")

-- Debug remote availability
print("Remote availability:")
print("PlaceUnit:", PlaceUnit and "Found" or "Not found")
print("SellUnit:", SellUnit and "Found" or "Not found")
print("PlaceDifficultyVote:", PlaceDifficultyVote and "Found" or "Not found")
print("SetUnitEquipped:", SetUnitEquipped and "Found" or "Not found")

local recordingsFolder = "recordings"
local recording = false
local currentRecording = {}
local replaying = false
local replayThread
local replayOptions = {Speed = 1, Loop = false, StartWaveOffset = 0}
local autoVote = false
local autoVoteChoice = "dif_normal"
local waveCache = {Current = 0, Max = 0}

-- Filesystem compatibility
local filesystem = {
    makeFolder = makefolder or (isfolder and function(name) if not isfolder(name) then return false end return true end) or function() return false end,
    isFolder = isfolder or function() return false end,
    listFiles = listfiles or function() return {} end,
    writeFile = writefile or function() return false end,
    readFile = readfile or function() return nil end
}

local function ensureFolder()
    if not filesystem.isFolder(recordingsFolder) then
        local success = filesystem.makeFolder(recordingsFolder)
        if not success then warn("Failed to create folder: "..recordingsFolder) end
        return success
    end
    return true
end

local function listRecordings()
    local out = {}
    local ok, files = pcall(filesystem.listFiles, recordingsFolder)
    if ok and type(files) == "table" then
        for _, f in ipairs(files) do
            local nm = f:match(recordingsFolder.."[/\\](.+)%.json$") or f:match("(.+)%.json$")
            if nm then table.insert(out, nm) end
        end
    else
        warn("Failed to list recordings: "..tostring(files))
    end
    return out
end

local function saveRecording(name, data)
    if not ensureFolder() then return false, "Failed to create folder" end
    local fname = recordingsFolder.."/"..name..".json"
    local ok, enc = pcall(HttpService.JSONEncode, HttpService, data)
    if not ok then return false, "JSON encode failed: "..tostring(enc) end
    local suc, err = pcall(filesystem.writeFile, fname, enc)
    if suc then return true end
    return false, "Write failed: "..tostring(err)
end

local function loadRecording(name)
    if not filesystem.readFile then return nil, "readFile not available" end
    local fname = recordingsFolder.."/"..name..".json"
    local ok, content = pcall(filesystem.readFile, fname)
    if not ok then return nil, "Read failed: "..tostring(content) end
    local ok2, dec = pcall(HttpService.JSONDecode, HttpService, content)
    if not ok2 then return nil, "JSON decode failed: "..tostring(dec) end
    return dec
end

local function getWaveText()
    local ok, txt = pcall(function()
        local gui = PlayerGui:FindFirstChild("GameGuiNoInset") or PlayerGui:FindFirstChild("GameGui")
        if not gui then return nil, "No GameGui found" end
        local screen = gui:FindFirstChild("Screen") or gui
        local top = screen:FindFirstChild("Top") or screen
        local info = top:FindFirstChild("GameInfo") or top
        local content = info:FindFirstChild("Content") or info
        local waves = content:FindFirstChild("Waves")
        if not waves then return nil, "No Waves GUI found" end
        local title = waves:FindFirstChild("Title")
        if not title then return nil, "No Title found" end
        return title.Text
    end)
    if not ok then return nil, "Error accessing GUI: "..tostring(txt) end
    return txt
end

local function updateWaveCache()
    local txt, err = getWaveText()
    if not txt then
        warn("Failed to update wave cache: "..tostring(err))
        return
    end
    local a, b = string.match(txt, "Wave%s*(%d+)%s*/%s*(%d+)")
    if a and b then
        waveCache.Current = tonumber(a) or 0
        waveCache.Max = tonumber(b) or 0
        return
    end
    local n = string.match(txt, "Wave%s*(%d+)")
    if n then
        waveCache.Current = tonumber(n) or 0
        return
    end
    local v = string.match(txt, "(%d+)%s*/%s*%d+")
    if v then
        waveCache.Current = tonumber(v) or 0
    end
end

local function recordAction(t)
    if not recording then return end
    table.insert(currentRecording, t)
end

local function safeCloneArgs(args)
    local out = {}
    for i, v in ipairs(args) do
        if typeof(v) == "CFrame" then
            out[i] = {__type="CFrame", Value = {v:components()}}
        elseif typeof(v) == "Vector3" then
            out[i] = {__type="Vector3", Value = {v.X, v.Y, v.Z}}
        elseif typeof(v) == "Instance" then
            out[i] = {__type="Instance", Value = v:GetFullName()}
        else
            out[i] = v
        end
    end
    return out
end

local function restoreArg(v)
    if type(v) == "table" and v.__type == "CFrame" and v.Value then
        local c = v.Value
        return CFrame.new(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
    elseif type(v) == "table" and v.__type == "Vector3" and v.Value then
        local c = v.Value
        return Vector3.new(c[1], c[2], c[3])
    else
        return v
    end
end

local hookAvailable = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function"
local oldHook
if hookAvailable then
    oldHook = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method == "InvokeServer" then
            if self == PlaceUnit then
                local args = {...}
                local copy = safeCloneArgs(args)
                recordAction({Type="Place", Args=copy, Wave=waveCache.Current, Time=os.time()})
            elseif self == SellUnit then
                local args = {...}
                local copy = safeCloneArgs(args)
                recordAction({Type="Sell", Args=copy, Wave=waveCache.Current, Time=os.time()})
            elseif self == PlaceDifficultyVote then
                local args = {...}
                local copy = safeCloneArgs(args)
                recordAction({Type="PlaceDifficultyVote", Args=copy, Wave=waveCache.Current, Time=os.time()})
            end
        end
        return oldHook(self, ...)
    end)
else
    local function hookInvoke(remote, orig)
        if not remote or not orig then return end
        remote.InvokeServer = function(self, ...)
            local args = {...}
            local copy = safeCloneArgs(args)
            local t = remote == PlaceUnit and "Place" or remote == SellUnit and "Sell" or "PlaceDifficultyVote"
            recordAction({Type=t, Args=copy, Wave=waveCache.Current, Time=os.time()})
            return orig(self, ...)
        end
    end
    if PlaceUnit and PlaceUnit.InvokeServer then hookInvoke(PlaceUnit, PlaceUnit.InvokeServer) end
    if SellUnit and SellUnit.InvokeServer then hookInvoke(SellUnit, SellUnit.InvokeServer) end
    if PlaceDifficultyVote and PlaceDifficultyVote.InvokeServer then hookInvoke(PlaceDifficultyVote, PlaceDifficultyVote.InvokeServer) end
end

local function playEntry(entry)
    if not entry or not entry.Type then return end
    local args = {}
    for i, v in ipairs(entry.Args or {}) do args[i] = restoreArg(v) end
    local ok, err = pcall(function()
        if entry.Type == "Place" and PlaceUnit then
            PlaceUnit:InvokeServer(unpack(args))
        elseif entry.Type == "Sell" and SellUnit then
            SellUnit:InvokeServer(unpack(args))
        elseif entry.Type == "PlaceDifficultyVote" and PlaceDifficultyVote then
            PlaceDifficultyVote:InvokeServer(unpack(args))
        end
    end)
    if not ok then warn("Failed to play entry: "..tostring(err)) end
end

local function startReplay(data, options)
    if replaying then return false, "Replay already in progress" end
    if not data or #data == 0 then return false, "No data to replay" end
    replaying = true
    options = options or {}
    replayOptions.Speed = math.clamp(options.Speed or replayOptions.Speed, 0.2, 4)
    replayOptions.Loop = options.Loop or replayOptions.Loop
    replayOptions.StartWaveOffset = math.max(0, options.StartWaveOffset or replayOptions.StartWaveOffset)
    replayThread = coroutine.create(function()
        while replaying do
            local idx = 1
            while replaying and idx <= #data do
                local entry = data[idx]
                local targetWave = (entry.Wave or 0) + replayOptions.StartWaveOffset
                updateWaveCache()
                local cur = waveCache.Current or 0
                if cur >= targetWave then
                    playEntry(entry)
                    idx = idx + 1
                    for _ = 1, math.max(1, math.floor(6/replayOptions.Speed)) do
                        if not replaying then break end
                        task.wait(0.05)
                    end
                else
                    task.wait(0.2)
                end
            end
            if not replayOptions.Loop then break end
        end
        replaying = false
        replayThread = nil
    end)
    local ok, err = pcall(coroutine.resume, replayThread)
    if not ok then
        replaying = false
        replayThread = nil
        return false, "Replay failed: "..tostring(err)
    end
    return true
end

local function stopReplay()
    replaying = false
    if replayThread then
        coroutine.close(replayThread)
        replayThread = nil
    end
end

local function scanHotbar()
    local out = {}
    local backpackGui = PlayerGui:FindFirstChild("BackpackGui") or PlayerGui:FindFirstChild("Backpack")
    if not backpackGui then return out, "No BackpackGui found" end
    local hotbar = backpackGui:FindFirstChild("Backpack") or backpackGui:FindFirstChild("Hotbar")
    if not hotbar then return out, "No Hotbar found" end
    for i = 1, 10 do
        local btn = hotbar:FindFirstChild(tostring(i)) or hotbar:FindFirstChild("Button"..i)
        if btn then
            local txt = btn:FindFirstChild("ToolName")
            if txt and (txt:IsA("TextBox") or txt:IsA("TextLabel")) then
                table.insert(out, {Index=i, Name=txt.Text})
            end
        end
    end
    return out
end

local function scanUnits()
    local UnitsFolder = ReplicatedStorage:FindFirstChild("Models") and ReplicatedStorage.Models:FindFirstChild("Units") or ReplicatedStorage:FindFirstChild("Units")
    local out = {}
    if not UnitsFolder then return out, "No Units folder found" end
    for _, v in ipairs(UnitsFolder:GetChildren()) do
        table.insert(out, v.Name)
    end
    return out
end

-- Enable Secure Mode for Wave
getgenv().SecureMode = true

-- Debugging: Log script start
print("Starting script in Wave...")

-- Load Rayfield
local Rayfield
local ok, err = pcall(function()
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
if not ok or not Rayfield then
    warn("Failed to load Rayfield: "..tostring(err))
    Rayfield = {
        CreateWindow = function() return {
            CreateTab = function() return {
                CreateSection = function() end,
                CreateButton = function() end,
                CreateInput = function() return {Value = ""} end,
                CreateDropdown = function() return {Value = "", Refresh = function() end} end,
                CreateSlider = function() end,
                CreateToggle = function() end
            } end
        },
        Notify = function(args) print(args.Title..": "..args.Content) end,
        LoadConfiguration = function() end
    }
end

-- Validate Rayfield methods
local function hasMethod(obj, method)
    return obj and type(obj[method]) == "function"
end
local Window
if hasMethod(Rayfield, "CreateWindow") then
    print("Initializing Rayfield UI...")
    Window = Rayfield:CreateWindow({
        Name = "Recorder",
        LoadingTitle = "Recorder",
        LoadingSubtitle = "Ready",
        ConfigurationSaving = {Enabled = true, FolderName = nil, FileName = "recorder_config"},
        ToggleUIKeybind = "K"
    })
    print("Rayfield UI initialized successfully")
else
    warn("Rayfield.CreateWindow is nil, UI creation skipped")
end

-- Notify user if UI is available
if Window and hasMethod(Rayfield, "Notify") then
    Rayfield:Notify({
        Title = "UI Loaded",
        Content = "Press 'K' to toggle the UI if it doesn't appear",
        Duration = 5
    })
elseif Window then
    print("UI Loaded: Press 'K' to toggle the UI if it doesn't appear")
else
    print("UI not created due to missing CreateWindow")
end

-- Helper function to safely create UI elements
local function safeCreateTab(window, name)
    if not window or not hasMethod(window, "CreateTab") then
        warn("Cannot create "..name.." tab: CreateTab is nil")
        return nil
    end
    return window:CreateTab(name)
end

local function safeCreateSection(tab, name)
    if not tab or not hasMethod(tab, "CreateSection") then
        warn("Cannot create "..name.." section: CreateSection is nil")
        return nil
    end
    return tab:CreateSection(name)
end

local function safeCreateButton(tab, config)
    if not tab or not hasMethod(tab, "CreateButton") then
        warn("Cannot create button: CreateButton is nil")
        return
    end
    tab:CreateButton(config)
end

local function safeCreateInput(tab, config)
    if not tab or not hasMethod(tab, "CreateInput") then
        warn("Cannot create input: CreateInput is nil")
        return nil
    end
    return tab:CreateInput(config)
end

local function safeCreateDropdown(tab, config)
    if not tab or not hasMethod(tab, "CreateDropdown") then
        warn("Cannot create dropdown: CreateDropdown is nil")
        return nil
    end
    return tab:CreateDropdown(config)
end

local function safeCreateSlider(tab, config)
    if not tab or not hasMethod(tab, "CreateSlider") then
        warn("Cannot create slider: CreateSlider is nil")
        return
    end
    tab:CreateSlider(config)
end

local function safeCreateToggle(tab, config)
    if not tab or not hasMethod(tab, "CreateToggle") then
        warn("Cannot create toggle: CreateToggle is nil")
        return
    end
    tab:CreateToggle(config)
end

-- Recorder Tab
local recTab = safeCreateTab(Window, "Recorder")
if recTab then
    local recSection = safeCreateSection(recTab, "Record Controls")
    if recSection then
        safeCreateButton(recTab, {
            Name = "Start Recording",
            Callback = function()
                currentRecording = {}
                recording = true
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Recording", Content = "Started recording", Duration = 3})
                else
                    print("Recording: Started recording")
                end
            end
        })
        safeCreateButton(recTab, {
            Name = "Stop Recording",
            Callback = function()
                recording = false
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Recording", Content = "Stopped recording", Duration = 3})
                else
                    print("Recording: Stopped recording")
                end
            end
        })
        local saveNameInput = safeCreateInput(recTab, {
            Name = "Filename",
            PlaceholderText = "session_name",
            RemoveTextAfterFocus = false,
            Callback = function() end
        })
        if saveNameInput then
            safeCreateButton(recTab, {
                Name = "Save",
                Callback = function()
                    local name = tostring(saveNameInput.Value ~= "" and saveNameInput.Value or ("rec_"..os.time()))
                    local ok, e = saveRecording(name, currentRecording)
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = ok and "Saved" or "Save Failed", Content = ok and name or tostring(e), Duration = 4})
                    else
                        print((ok and "Saved" or "Save Failed")..": "..(ok and name or tostring(e)))
                    end
                end
            })
        end
    end
    local recViewSection = safeCreateSection(recTab, "Live")
    if recViewSection then
        safeCreateButton(recTab, {
            Name = "Show Current Length",
            Callback = function()
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Recording", Content = tostring(#currentRecording).." actions", Duration = 3})
                else
                    print("Recording: "..tostring(#currentRecording).." actions")
                end
            end
        })
        safeCreateButton(recTab, {
            Name = "Clear Current",
            Callback = function()
                currentRecording = {}
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Cleared", Content = "Current recording cleared", Duration = 3})
                else
                    print("Cleared: Current recording cleared")
                end
            end
        })
    end
end

-- Replayer Tab
local replayTab = safeCreateTab(Window, "Replayer")
if replayTab then
    local replaySection = safeCreateSection(replayTab, "Files & Playback")
    if replaySection then
        local files = listRecordings()
        local filesDropdown = safeCreateDropdown(replayTab, {
            Name = "Recordings",
            Options = files,
            MultiSelection = false,
            Callback = function() end
        })
        safeCreateButton(replayTab, {
            Name = "Refresh",
            Callback = function()
                local newFiles = listRecordings()
                if filesDropdown and hasMethod(filesDropdown, "Refresh") then
                    filesDropdown:Refresh(newFiles)
                end
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Refreshed", Content = "Loaded "..#newFiles.." recordings", Duration = 3})
                else
                    print("Refreshed: Loaded "..#newFiles.." recordings")
                end
            end
        })
        safeCreateButton(replayTab, {
            Name = "Load Selected",
            Callback = function()
                local sel = filesDropdown and filesDropdown.Value
                if type(sel) == "table" then sel = sel[1] end
                if not sel or sel == "" then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "No File", Content = "Select a file to load", Duration = 3})
                    else
                        print("No File: Select a file to load")
                    end
                    return
                end
                local data, e = loadRecording(sel)
                if data then
                    currentRecording = data
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Loaded", Content = sel, Duration = 3})
                    else
                        print("Loaded: "..sel)
                    end
                else
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Load Failed", Content = tostring(e), Duration = 4})
                    else
                        print("Load Failed: "..tostring(e))
                    end
                end
            end
        })
        safeCreateButton(replayTab, {
            Name = "Start Replay",
            Callback = function()
                if #currentRecording == 0 then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "No Data", Content = "Load or record first", Duration = 3})
                    else
                        print("No Data: Load or record first")
                    end
                    return
                end
                local ok, err = startReplay(currentRecording, {Speed = replayOptions.Speed, Loop = replayOptions.Loop, StartWaveOffset = replayOptions.StartWaveOffset})
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = ok and "Replay Started" or "Replay Failed", Content = ok and "Playing "..#currentRecording.." actions" or tostring(err), Duration = 4})
                else
                    print((ok and "Replay Started" or "Replay Failed")..": "..(ok and "Playing "..#currentRecording.." actions" or tostring(err)))
                end
            end
        })
        safeCreateButton(replayTab, {
            Name = "Stop Replay",
            Callback = function()
                stopReplay()
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Stopped", Content = "Replay stopped", Duration = 3})
                else
                    print("Stopped: Replay stopped")
                end
            end
        })
        safeCreateSlider(replayTab, {
            Name = "Speed",
            Range = {0.2, 4},
            Increment = 0.1,
            Suffix = "x",
            CurrentValue = 1,
            Callback = function(v)
                replayOptions.Speed = v
            end
        })
        safeCreateToggle(replayTab, {
            Name = "Loop",
            CurrentValue = false,
            Callback = function(v)
                replayOptions.Loop = v
            end
        })
        local startWaveInput = safeCreateInput(replayTab, {
            Name = "Start Wave Offset",
            PlaceholderText = "0",
            RemoveTextAfterFocus = false,
            Callback = function(v)
                replayOptions.StartWaveOffset = tonumber(v) or 0
            end
        })
    end
end

-- Tools Tab
local toolsTab = safeCreateTab(Window, "Tools")
if toolsTab then
    local toolsSection = safeCreateSection(toolsTab, "Scans & Vote")
    if toolsSection then
        safeCreateButton(toolsTab, {
            Name = "Scan Hotbar",
            Callback = function()
                local h, err = scanHotbar()
                local s = ""
                for _, v in ipairs(h) do s = s..v.Index..": "..(v.Name or "nil").."\n" end
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Hotbar", Content = s ~= "" and s or (err or "Empty hotbar"), Duration = 6})
                else
                    print("Hotbar: "..(s ~= "" and s or (err or "Empty hotbar")))
                end
            end
        })
        safeCreateButton(toolsTab, {
            Name = "Scan Units Folder",
            Callback = function()
                local u, err = scanUnits()
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Units", Content = u and ("Found "..#u.." units") or (err or "No units found"), Duration = 4})
                else
                    print("Units: "..(u and ("Found "..#u.." units") or (err or "No units found")))
                end
            end
        })
        safeCreateToggle(toolsTab, {
            Name = "Auto Vote",
            CurrentValue = false,
            Callback = function(v)
                autoVote = v
            end
        })
        local diffDropdown = safeCreateDropdown(toolsTab, {
            Name = "Difficulty",
            Options = {"dif_normal", "dif_hard", "dif_insane"},
            MultiSelection = false,
            Callback = function(v)
                autoVoteChoice = type(v) == "table" and v[1] or v
            end
        })
        safeCreateButton(toolsTab, {
            Name = "Send Vote Now",
            Callback = function()
                if not PlaceDifficultyVote or not PlaceDifficultyVote.InvokeServer then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Vote Failed", Content = "PlaceDifficultyVote unavailable", Duration = 3})
                    else
                        print("Vote Failed: PlaceDifficultyVote unavailable")
                    end
                    return
                end
                local diff = autoVoteChoice or "dif_normal"
                local ok, err = pcall(PlaceDifficultyVote.InvokeServer, PlaceDifficultyVote, diff)
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = ok and "Vote Sent" or "Vote Failed", Content = ok and ("Voted for "..diff) or tostring(err), Duration = 3})
                else
                    print((ok and "Vote Sent" or "Vote Failed")..": "..(ok and ("Voted for "..diff) or tostring(err)))
                end
            end
        })
    end
end

-- Lobby Tab
local lobbyTab = safeCreateTab(Window, "Lobby")
if lobbyTab then
    local lobbySection = safeCreateSection(lobbyTab, "Unit Equipment")
    if lobbySection then
        local unitInput = safeCreateInput(lobbyTab, {
            Name = "Unit Name",
            PlaceholderText = "e.g., unique_1",
            RemoveTextAfterFocus = false,
            Callback = function() end
        })
        safeCreateButton(lobbyTab, {
            Name = "Equip Unit",
            Callback = function()
                if not SetUnitEquipped or not SetUnitEquipped.InvokeServer then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Equip Failed", Content = "SetUnitEquipped remote unavailable", Duration = 3})
                    else
                        print("Equip Failed: SetUnitEquipped remote unavailable")
                    end
                    return
                end
                local unitName = unitInput and unitInput.Value or ""
                if not unitName or unitName == "" then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Equip Failed", Content = "Enter a unit name", Duration = 3})
                    else
                        print("Equip Failed: Enter a unit name")
                    end
                    return
                end
                local ok, err = pcall(SetUnitEquipped.InvokeServer, SetUnitEquipped, unitName, true)
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = ok and "Equipped" or "Equip Failed", Content = ok and ("Equipped "..unitName) or tostring(err), Duration = 3})
                else
                    print((ok and "Equipped" or "Equip Failed")..": "..(ok and ("Equipped "..unitName) or tostring(err)))
                end
            end
        })
        safeCreateButton(lobbyTab, {
            Name = "Unequip Unit",
            Callback = function()
                if not SetUnitEquipped or not SetUnitEquipped.InvokeServer then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Unequip Failed", Content = "SetUnitEquipped remote unavailable", Duration = 3})
                    else
                        print("Unequip Failed: SetUnitEquipped remote unavailable")
                    end
                    return
                end
                local unitName = unitInput and unitInput.Value or ""
                if not unitName or unitName == "" then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Unequip Failed", Content = "Enter a unit name", Duration = 3})
                    else
                        print("Unequip Failed: Enter a unit name")
                    end
                    return
                end
                local ok, err = pcall(SetUnitEquipped.InvokeServer, SetUnitEquipped, unitName, false)
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = ok and "Unequipped" or "Unequip Failed", Content = ok and ("Unequipped "..unitName) or tostring(err), Duration = 3})
                else
                    print((ok and "Unequipped" or "Unequip Failed")..": "..(ok and ("Unequipped "..unitName) or tostring(err)))
                end
            end
        })
    end
end

-- Misc Tab
local miscTab = safeCreateTab(Window, "Misc")
if miscTab then
    local miscSection = safeCreateSection(miscTab, "Options")
    if miscSection then
        safeCreateButton(miscTab, {
            Name = "Current Wave",
            Callback = function()
                updateWaveCache()
                if hasMethod(Rayfield, "Notify") then
                    Rayfield:Notify({Title = "Wave", Content = tostring(waveCache.Current).."/"..tostring(waveCache.Max), Duration = 3})
                else
                    print("Wave: "..tostring(waveCache.Current).."/"..tostring(waveCache.Max))
                end
            end
        })
        safeCreateButton(miscTab, {
            Name = "Export Current (clipboard)",
            Callback = function()
                local ok, enc = pcall(HttpService.JSONEncode, HttpService, currentRecording)
                if ok and setclipboard then
                    setclipboard(enc)
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Exported", Content = "Copied to clipboard", Duration = 3})
                    else
                        print("Exported: Copied to clipboard")
                    end
                else
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Export Failed", Content = tostring(enc or "No setclipboard"), Duration = 3})
                    else
                        print("Export Failed: "..tostring(enc or "No setclipboard"))
                    end
                end
            end
        })
        safeCreateButton(miscTab, {
            Name = "Import from Clipboard",
            Callback = function()
                if not getclipboard then
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "No Clipboard", Content = "getclipboard unavailable", Duration = 3})
                    else
                        print("No Clipboard: getclipboard unavailable")
                    end
                    return
                end
                local str = getclipboard()
                local ok, dec = pcall(HttpService.JSONDecode, HttpService, str)
                if ok and type(dec) == "table" then
                    currentRecording = dec
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Imported", Content = "Recording loaded", Duration = 3})
                    else
                        print("Imported: Recording loaded")
                    end
                else
                    if hasMethod(Rayfield, "Notify") then
                        Rayfield:Notify({Title = "Import Failed", Content = "Invalid JSON: "..tostring(dec), Duration = 3})
                    else
                        print("Import Failed: Invalid JSON: "..tostring(dec))
                    end
                end
            end
        })
    end
end

-- Initialize recordings and load configuration
ensureFolder()
if Window and hasMethod(Window, "CreateTab") and recTab and hasMethod(recTab, "CreateDropdown") then
    local files = listRecordings()
    local filesDropdown = safeCreateDropdown(recTab, {
        Name = "Recordings",
        Options = files,
        MultiSelection = false,
        Callback = function() end
    })
    if filesDropdown and hasMethod(filesDropdown, "Refresh") then
        filesDropdown:Refresh(files)
    end
end
if hasMethod(Rayfield, "LoadConfiguration") then
    Rayfield:LoadConfiguration()
else
    print("Cannot load configuration: LoadConfiguration is nil")
end

-- Background tasks
task.spawn(function()
    while true do
        if autoVote and PlaceDifficultyVote and PlaceDifficultyVote.InvokeServer then
            local ok, err = pcall(PlaceDifficultyVote.InvokeServer, PlaceDifficultyVote, autoVoteChoice)
            if not ok then warn("Auto-vote failed: "..tostring(err)) end
            task.wait(5)
        else
            task.wait(0.8)
        end
        updateWaveCache()
    end
end)

RunService.Heartbeat:Connect(function()
    if recording then
        -- Live updates can be added here if needed
    end
end)
