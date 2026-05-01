local PORT = 14113
local PROTOCOL = "adamco_universal_controller"

local TICK_RATE = 0.05
local THROTTLE_GAIN = 5
local BRAKE_GAIN = 5
local MAX_RPM = 256
local MIN_RPM = 0
local RPM_DIRECTION = 1;

local ENABLED_COMMANDS = {
    rpm_delta = true,
    set_rpm = true,
    toggle_engine = false,
    autopilot = false,
}

local DEBUG = true

local function log(...)
    if DEBUG then print(...) end
end

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function tableContains(t, value)
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

local function toSet(t)
    local set = {}
    for _, v in ipairs(t) do
        set[v] = true
    end
    return set
end

local function getMethodSet(peripheralName)
    local methodSet = {}
    local ok, methods = pcall(peripheral.getMethods, peripheralName)
    if not ok or not methods then return methodSet end

    for _, method in ipairs(methods) do
        methodSet[method] = true
    end

    return methodSet
end

local function findFirstPeripheralByType(typeName)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == typeName then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

local modem, modemName = peripheral.find("modem")
if not modem then
    error("No modem found")
end
modem.open(PORT)

local speedController = nil
local speedControllerName = nil
local speedControllerMethods = nil

local typewriter, typewriterName = findFirstPeripheralByType("linked_typewriter")

for _, name in ipairs(peripheral.getNames()) do
    local peripheralType = peripheral.getType(name)
    log("Peripheral:", name, peripheralType)

    if peripheralType == "Create_RotationSpeedController" then
        speedController = peripheral.wrap(name)
        speedControllerName = name
        speedControllerMethods = getMethodSet(name)
    end
end

local function getTargetSpeed()
    if not speedController then return 0 end

    if speedControllerMethods and speedControllerMethods.getTargetSpeed then
        local ok, result = pcall(speedController.getTargetSpeed)
        if ok and type(result) == "number" then return result end
    end

    if speedControllerMethods and speedControllerMethods.getSpeed then
        local ok, result = pcall(speedController.getSpeed)
        if ok and type(result) == "number" then return result end
    end

    return _G.__lastTargetSpeed or 0
end

local function setTargetSpeed(rpm)
    if not speedController then return end

    rpm = clamp(math.floor(rpm + 0.5), MIN_RPM, MAX_RPM)
    _G.__lastTargetSpeed = rpm

    local ok, err = pcall(speedController.setTargetSpeed, rpm)
    if not ok then
        print("Failed to set speed:", err)
    end
end

local function adjustTargetSpeed(delta)
    local current = getTargetSpeed()
    setTargetSpeed(current + delta)
end

local function ToggleEngine()
    print("ToggleEngine called")
end

local function SetAutoPilot(enabled)
    print("SetAutoPilot called:", enabled)
end

local function makeCommand(commandType, payload, pressedKeys)
    return {
        protocol = PROTOCOL,
        type = commandType,
        source = os.getComputerID(),
        payload = payload or {},
        keys = pressedKeys,
    }
end

local function sendCommand(commandType, payload, pressedKeys)
    modem.transmit(PORT, PORT, makeCommand(commandType, payload, pressedKeys))
    log("Broadcast command:", commandType)
end

local function broadcastTypewriterCommands()
    print("Mode: TYPEWRITER BROADCASTER")
    print("Typewriter:", typewriterName)
    print("Broadcasting on port", PORT)
    print("Hold SPACE to increase RPM. Hold LEFT CTRL to decrease RPM.")
    print("Press F to toggle engine.")
    print("Press G to toggle autopilot.")

    local lastPressedSet = {}
    local autoPilotEnabled = false

    while true do
        local pressed = typewriter.getPressedKeyCodes()
        local currentPressedSet = toSet(pressed)
        local delta = 0

        -- Continuous RPM commands
        if tableContains(pressed, keys.space) then
            delta = delta + THROTTLE_GAIN
        end

        if tableContains(pressed, keys.leftCtrl) then
            delta = delta - BRAKE_GAIN
        end

        if delta ~= 0 then
            sendCommand("rpm_delta", { delta = delta }, pressed)
        end

        -- One-shot command: F
        if currentPressedSet[keys.f] and not lastPressedSet[keys.f] then
            sendCommand("toggle_engine", {}, pressed)
        end

        -- One-shot command: G
        if currentPressedSet[keys.g] and not lastPressedSet[keys.g] then
            autoPilotEnabled = not autoPilotEnabled
            sendCommand("autopilot", { enabled = autoPilotEnabled }, pressed)
        end

        lastPressedSet = currentPressedSet
        sleep(TICK_RATE)
    end
end

local function isCommandEnabled(commandType)
    return ENABLED_COMMANDS[commandType] == true
end

local function listenForCommands()
    print("Mode: COMMAND LISTENER")
    print("Listening on port", PORT)

    if speedController then
        print("Speed controller:", speedControllerName)
    else
        print("No Create_RotationSpeedController found. Commands will be received but not applied.")
    end

    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

        if channel == PORT and type(message) == "table" and message.protocol == PROTOCOL then
            if message.source ~= os.getComputerID() then
                if not isCommandEnabled(message.type) then
                    
                    log("Ignored disabled command: ", tostring(message.type))
                    goto continue
                end
                if message.type == "rpm_delta" then
                    local delta = nil

                    if type(message.payload) == "table" then
                        delta = message.payload.delta
                    end

                    if type(delta) == "number" then
                        adjustTargetSpeed(delta * RPM_DIRECTION)
                        log("Applied RPM delta:", delta * RPM_DIRECTION, "New target:", getTargetSpeed())
                    end

                elseif message.type == "set_rpm" then
                    local rpm = nil

                    if type(message.payload) == "table" then
                        rpm = message.payload.rpm
                    end

                    if type(rpm) == "number" then
                        setTargetSpeed(rpm * RPM_DIRECTION)
                        log("Set RPM:", rpm * RPM_DIRECTION)
                    end

                elseif message.type == "toggle_engine" then
                    ToggleEngine()

                elseif message.type == "autopilot" then
                    local enabled = nil

                    if type(message.payload) == "table" then
                        enabled = message.payload.enabled
                    end

                    SetAutoPilot(enabled)

                else
                    log("Unknown command type:", tostring(message.type))
                end
            end
        end
        ::continue::
    end
end

if typewriter then
    broadcastTypewriterCommands()
else
    listenForCommands()
end
