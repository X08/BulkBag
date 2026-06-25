-- BulkBag: Ctrl+drag to select items, LMB empty slot to bulk move
-- Supports inventory bags, personal bank, and guild bank

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local HIGHLIGHT_COLOR = {r=0.2, g=0.6, b=1.0, a=0.5}
local MOVE_INTERVAL   = 0.05  -- seconds between queued moves

local TYPE_CONTAINER = "container"
local TYPE_BANK      = "bank"
local TYPE_GUILDBANK = "guildbank"

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local selected        = {}     -- currently highlighted slots
local reservedSlots   = {}     -- destination slots already queued
local moveQueue       = {}     -- pending moves
local isDragging      = false
local dragMode        = nil    -- "select" or "deselect"
local isMoving        = false
local waitingForUpdate = false
local currentTarget   = nil    -- target bag for active move operation
local frameTick       = 0

------------------------------------------------------------------------
-- Slot utilities
------------------------------------------------------------------------

local function GetSlotKey(slotType, bagID, slotID)
    if slotType == TYPE_BANK      then return "bank_" .. slotID end
    if slotType == TYPE_GUILDBANK then return "guild_" .. bagID .. "_" .. slotID end
    return "bag_" .. bagID .. "_" .. slotID
end

-- Container slots: visual slot 1 = bottom-right, API slot 1 = top-left
local function ToAPISlot(bagID, visualSlot)
    return (GetContainerNumSlots(bagID) + 1) - visualSlot
end

local function GetButton(slotType, bagID, slotID)
    if slotType == TYPE_BANK then
        return _G["BankFrameItem" .. slotID]
    elseif slotType == TYPE_GUILDBANK then
        local col = math.ceil(slotID / 14)
        local row = slotID - (col - 1) * 14
        return _G["GuildBankColumn" .. col .. "Button" .. row]
    else
        return _G["ContainerFrame" .. (bagID + 1) .. "Item" .. slotID]
    end
end

local function IsSlotEmpty(slotType, bagID, slotID)
    if slotType == TYPE_BANK then
        local btn = _G["BankFrameItem" .. slotID]
        return btn and not btn.hasItem
    elseif slotType == TYPE_GUILDBANK then
        return not GetGuildBankItemLink(bagID, slotID)
    else
        return not GetContainerItemLink(bagID, ToAPISlot(bagID, slotID))
    end
end

------------------------------------------------------------------------
-- Highlight
------------------------------------------------------------------------

local function HighlightSlot(button, on)
    if not button._bbOverlay then
        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(button)
        tex:SetTexture(1, 1, 1, 1)
        button._bbOverlay = tex
    end
    if on then
        button._bbOverlay:SetVertexColor(HIGHLIGHT_COLOR.r, HIGHLIGHT_COLOR.g, HIGHLIGHT_COLOR.b, HIGHLIGHT_COLOR.a)
        button._bbOverlay:Show()
    else
        button._bbOverlay:Hide()
    end
end

------------------------------------------------------------------------
-- Selection
------------------------------------------------------------------------

local function IsSelected(slotType, bagID, slotID)
    return selected[GetSlotKey(slotType, bagID, slotID)] ~= nil
end

local function SelectSlot(slotType, bagID, slotID, button)
    selected[GetSlotKey(slotType, bagID, slotID)] = { slotType = slotType, bagID = bagID, slotID = slotID }
    HighlightSlot(button, true)
end

local function DeselectSlot(slotType, bagID, slotID, button)
    selected[GetSlotKey(slotType, bagID, slotID)] = nil
    HighlightSlot(button, false)
end

local function ClearSelection()
    for _, data in pairs(selected) do
        local btn = GetButton(data.slotType, data.bagID, data.slotID)
        if btn then HighlightSlot(btn, false) end
    end
    selected = {}
end

------------------------------------------------------------------------
-- Move queue
------------------------------------------------------------------------

local function GetFreeSlots(target)
    local free = {}
    if target.slotType == TYPE_BANK then
        for slotID = 1, 28 do
            local btn = _G["BankFrameItem" .. slotID]
            if btn and not btn.hasItem and not reservedSlots[GetSlotKey(TYPE_BANK, 0, slotID)] then
                table.insert(free, slotID)
            end
        end
    elseif target.slotType == TYPE_GUILDBANK then
        local tabID = target.bagID
        for slotID = 1, 98 do
            if not GetGuildBankItemLink(tabID, slotID) and not reservedSlots[GetSlotKey(TYPE_GUILDBANK, tabID, slotID)] then
                table.insert(free, slotID)
            end
        end
    else
        local bagID = target.bagID
        local numSlots = GetContainerNumSlots(bagID)
        for visualSlot = numSlots, 1, -1 do
            local key = GetSlotKey(TYPE_CONTAINER, bagID, visualSlot)
            if not GetContainerItemLink(bagID, (numSlots + 1) - visualSlot)
                and not IsSelected(TYPE_CONTAINER, bagID, visualSlot)
                and not reservedSlots[key] then
                table.insert(free, visualSlot)
            end
        end
    end
    return free
end

local function BuildQueue(target)
    local freeSlots = GetFreeSlots(target)

    local sortedSelected = {}
    for _, data in pairs(selected) do
        if not (data.slotType == target.slotType and data.bagID == target.bagID) then
            table.insert(sortedSelected, data)
        end
    end
    table.sort(sortedSelected, function(a, b)
        if a.bagID ~= b.bagID then return a.bagID < b.bagID end
        return a.slotID > b.slotID
    end)

    moveQueue = {}
    local freeIndex = 1
    for _, data in ipairs(sortedSelected) do
        if freeIndex > #freeSlots then break end
        local dstSlot = freeSlots[freeIndex]
        reservedSlots[GetSlotKey(target.slotType, target.bagID, dstSlot)] = true
        table.insert(moveQueue, {
            srcType = data.slotType, srcBag = data.bagID, srcSlot = data.slotID,
            dstType = target.slotType, dstBag = target.bagID, dstSlot = dstSlot,
        })
        freeIndex = freeIndex + 1
    end
end

local function ExecuteMove(move)
    -- Pick up source
    if move.srcType == TYPE_BANK then
        local btn = GetButton(TYPE_BANK, 0, move.srcSlot)
        if btn then btn:Click() end
    elseif move.srcType == TYPE_GUILDBANK then
        PickupGuildBankItem(move.srcBag, move.srcSlot)
    else
        PickupContainerItem(move.srcBag, ToAPISlot(move.srcBag, move.srcSlot))
    end
    -- Place at destination
    if move.dstType == TYPE_BANK then
        local btn = GetButton(TYPE_BANK, 0, move.dstSlot)
        if btn then btn:Click() end
    elseif move.dstType == TYPE_GUILDBANK then
        PickupGuildBankItem(move.dstBag, move.dstSlot)
    else
        PickupContainerItem(move.dstBag, ToAPISlot(move.dstBag, move.dstSlot))
    end
end

local function DequeueMove()
    if #moveQueue == 0 then
        isMoving        = false
        waitingForUpdate = false
        currentTarget   = nil
        reservedSlots   = {}
        local remaining = 0
        for _ in pairs(selected) do remaining = remaining + 1 end
        if remaining > 0 then
            print(string.format("BulkBag: %d item(s) could not be moved, target full", remaining))
        end
        return
    end

    local move = table.remove(moveQueue, 1)
    ExecuteMove(move)

    local key = GetSlotKey(move.srcType, move.srcBag, move.srcSlot)
    if selected[key] then
        local btn = GetButton(move.srcType, move.srcBag, move.srcSlot)
        if btn then HighlightSlot(btn, false) end
        selected[key] = nil
    end

    waitingForUpdate = true
end

local function MoveSelectedTo(target)
    currentTarget = target
    reservedSlots = {}
    BuildQueue(target)
    if #moveQueue > 0 then
        isMoving        = true
        waitingForUpdate = false
    else
        print("BulkBag: no free slots in target")
    end
end

------------------------------------------------------------------------
-- Hooking
------------------------------------------------------------------------

local function HookButton(btn, slotType, bagID, slotID)
    if not btn or btn._bbHooked then return end
    btn._bbHooked = true

    btn:HookScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end

        if IsControlKeyDown() then
            isDragging = true
            if IsSelected(slotType, bagID, slotID) then
                dragMode = "deselect"
                DeselectSlot(slotType, bagID, slotID, self)
            else
                dragMode = "select"
                SelectSlot(slotType, bagID, slotID, self)
            end
            return
        end

        if next(selected) and IsSlotEmpty(slotType, bagID, slotID) and not IsSelected(slotType, bagID, slotID) then
            MoveSelectedTo({ slotType = slotType, bagID = bagID })
        else
            ClearSelection()
        end
    end)

    btn:HookScript("OnEnter", function(self)
        if not isDragging then return end
        if dragMode == "select" then
            SelectSlot(slotType, bagID, slotID, self)
        else
            DeselectSlot(slotType, bagID, slotID, self)
        end
    end)
end

local function HookInventoryBags()
    for bagID = 0, 4 do
        for slotID = 1, GetContainerNumSlots(bagID) do
            HookButton(_G["ContainerFrame" .. (bagID + 1) .. "Item" .. slotID], TYPE_CONTAINER, bagID, slotID)
        end
    end
end

local function HookBankSlots()
    for slotID = 1, 28 do
        HookButton(_G["BankFrameItem" .. slotID], TYPE_BANK, 0, slotID)
    end
    for bagID = 5, 10 do
        for slotID = 1, GetContainerNumSlots(bagID) do
            HookButton(_G["ContainerFrame" .. (bagID + 1) .. "Item" .. slotID], TYPE_CONTAINER, bagID, slotID)
        end
    end
end

local function HookGuildBankSlots()
    local tabID = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
    for col = 1, 7 do
        for row = 1, 14 do
            HookButton(_G["GuildBankColumn" .. col .. "Button" .. row], TYPE_GUILDBANK, tabID, (col - 1) * 14 + row)
        end
    end
end

------------------------------------------------------------------------
-- Event and update loop
------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("GUILDBANKFRAME_OPENED")
f:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" or event == "BAG_UPDATE" then
        HookInventoryBags()
        if isMoving and waitingForUpdate then waitingForUpdate = false end
    elseif event == "BANKFRAME_OPENED" then
        HookBankSlots()
    elseif event == "GUILDBANKFRAME_OPENED" or event == "GUILDBANKBAGSLOTS_CHANGED" then
        HookGuildBankSlots()
        if isMoving and waitingForUpdate then waitingForUpdate = false end
    end
end)

f:SetScript("OnUpdate", function(self, elapsed)
    if isDragging and not IsMouseButtonDown("LeftButton") then
        isDragging = false
        dragMode   = nil
    end
    if isMoving and not waitingForUpdate then
        frameTick = frameTick + elapsed
        if frameTick >= MOVE_INTERVAL then
            frameTick = 0
            DequeueMove()
        end
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

SLASH_BULKBAG1 = "/bb"
SlashCmdList["BULKBAG"] = function(msg)
    if msg == "clear" then
        ClearSelection()
        print("BulkBag: selection cleared")
    else
        local count = 0
        for _, data in pairs(selected) do
            print(string.format("  %s bag=%d slot=%d", data.slotType, data.bagID, data.slotID))
            count = count + 1
        end
        print(string.format("BulkBag: %d item(s) selected", count))
    end
end
