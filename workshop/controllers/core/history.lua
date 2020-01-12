--[[ 
    The history ui window is managed in another module

    Example Usuage:
    local history = require(thismodule)
    
    local selection = {obj1, obj2}
    history.beginAction(selection, "testAction")
    
    obj1.colour = colour:random()
    something(obj2)

    history.endAction()

]]

local limit = 100 -- how many actions can we store

local shared = require("tevgit:workshop/controllers/shared.lua")

local pointer = limit
local actions = {}

-- used internally to prevent unfinished actions
local actionInProgress = false

local callback = nil

-- Used to track changes during an action
local changes = {}
local destroyedObjects = {}
local newObjects = {}

local eventListeners = {}
local actionName = ""

local changedListener, ChildAddedListener, destroyingListener;

local function registerEvents(object)
    table.insert(eventListeners, object:onSync("changed", changedListener))
    table.insert(eventListeners, object:onSync("childAdded", ChildAddedListener))
    table.insert(eventListeners, object:onSync("destroying", destroyingListener))
end

-- oldValue added to changed event from "POTATO 0.7.0"
changedListener = function (property, value, oldValue)
    local changedObject = self.object
    if not changes[changedObject] then
        changes[changedObject] = {}
    end 
    
    if not changes[changedObject][property] then
        changes[changedObject][property] = {oldValue, value}
    else
        -- do not change the old value, we've already recorded it.
        changes[changedObject][property][2] = value 
    end
end

destroyingListener = function()
    local changedObject = self.object
    if not changes[changedObject] then
        changes[changedObject] = {}
    end 
    -- Object is being destroyed, let's save a copy of all their writable properties so the user can undo this action
    local members = shared.workshop:getMembersOfObject( changedObject )
    local toStore = {}
    for _, prop in pairs(members) do
        local val = changedObject[prop.property]
        local pType = type(val)

        if prop.writable and pType ~= "function" then
            -- We can save it and re-construct it
            toStore[prop.property] = val
        end
    end

    toStore["parent"] = changedObject.parent
    toStore["className"] = changedObject.className
    toStore["_ref"] = changedObject

    table.insert(destroyedObjects, toStore)
end

ChildAddedListener = function(child)
    local changedObject = child
    if not changes[changedObject] then
        changes[changedObject] = {}
    end 
    -- Object is being destroyed, let's save a copy of all their writable properties so the user can undo this action
    local members = shared.workshop:getMembersOfObject( changedObject )
    local toStore = {}
    for _, prop in pairs(members) do
        local val = changedObject[prop.property]
        local pType = type(val)

        if prop.writable and pType ~= "function" then
            -- We can save it and re-construct it
            toStore[prop.property] = val
        end
    end

    toStore["parent"] = changedObject.parent
    toStore["className"] = changedObject.className
    toStore["_ref"] = changedObject
    registerEvents(changedObject)

    table.insert(newObjects, toStore)
end

local function count(dictionary)
    local i = 0
    for _,v in pairs(dictionary) do i = i + 1 end
    return i
end

-- Tell this module that we're about to change some things
-- the module will register changed callbacks to record the before/after
--
-- object : table of teverse objects or teverse object
-- name : name of the event/action
--
-- you need to call endAction after completing your changes to the objects
local function beginAction( object, name )
    assert(not actionInProgress, "please use endAction before starting another")

    actions[pointer+1] = nil

    actionInProgress = true
    actionName = name or ""
    if type(object) == "table" then
        for _,v in pairs(object) do
            registerEvents(v)
        end
    else
        registerEvents(object)
    end
end

local function endAction()
    assert(actionInProgress, "you must call beginAction first")

    -- stop listening to the objects
    for _,v in pairs(eventListeners) do
        v:disconnect()
    end
    eventListeners = {}
    
    -- if nothing changed dont create an action
    if count(changes) > 0 or count(destroyedObjects) > 0 or count(newObjects) > 0 then
        pointer = pointer + 1
        if pointer >= limit then
            actions[pointer - limit] = nil
        end

        actions[pointer] = {os.time(), actionName, changes, destroyedObjects, newObjects}
        changes = {}
        destroyedObjects = {}
        newObjects = {}

        if type(callback) == "function" then
            callback()
        end
    end
    
    actionInProgress = false
end 

local function updateReferences(old, new)
    for p, a in pairs(actions) do
        local newTbl = {}
        for ref, props in pairs(a[3]) do
            if ref ~= old then
                newTbl[ref] = props
            else
                newTbl[new] = props
            end
        end
        a[3] = newTbl
    end
end

local function undo()
    if actions[pointer] ~= nil then

        -- destroyed objects (restore)
        for _, properties in pairs(actions[pointer][4]) do 
            local obj = engine[properties["className"]]()
            for property, value in pairs(properties) do
                obj[property] = value
            end
            local oldRef = properties["_ref"]
            properties["_ref"] = obj
            updateReferences(oldRef, obj)
        end

        -- created objects (destroy)
        for _,properties in pairs(actions[pointer][5]) do 
            if properties["_ref"].alive then
                properties["_ref"]:destroy()
            end
        end

        for object, properties in pairs(actions[pointer][3]) do 
            if object and object.alive then
                for property, values in pairs(properties) do
                    --values[1] = original value
                    --values[2] = changed value
                    object[property] = values[1]
                end
            else
                for k,v in pairs(properties) do print(k,v) end
                warn("There was a change recorded, but we couldn't find the object.")
            end
        end

        pointer = pointer - 1

        if type(callback) == "function" then
            callback()
        end
    else
        print("nothing to undo")
    end
end

local function redo()
    if actions[pointer + 1] ~= nil then
        pointer = pointer + 1

        -- destroyed objects (destroy)
        for _, properties in pairs(actions[pointer][4]) do 
            if properties["_ref"].alive then
                properties["_ref"]:destroy()
            end
        end

        -- created objects (create)
        for _,properties in pairs(actions[pointer][5]) do 
            local obj = engine[properties["className"]]()
            for property, value in pairs(properties) do
                obj[property] = value
            end
            local oldRef = properties["_ref"]
            properties["_ref"] = obj
            updateReferences(oldRef, obj)
        end

        for object, properties in pairs(actions[pointer][3]) do 
            if object and object.alive then
                for property, values in pairs(properties) do
                    --values[1] = original value
                    --values[2] = changed value
                    object[property] = values[2]
                end
            else
                warn("There was a change recorded, but we couldn't find the object.")
            end
        end

        if type(callback) == "function" then
            callback()
        end
    else
        print("nothing to redo")
    end
end

local keybinder = require("tevgit:workshop/controllers/core/keybinder.lua")

keybinder:bind({
    name = "undo",
    priorKey = enums.key.leftCtrl,
    key = enums.key.z,
    action = function ()
        if not engine.input:isKeyDown(enums.key.leftShift) then
            undo()
        else
            redo()
        end
    end
})

keybinder:bind({
    name = "redo",
    priorKey = enums.key.leftCtrl,
    key = enums.key.y,
    action = redo
})

return {
    beginAction = beginAction,
    endAction = endAction,

    getActions = function() return actions end,
    getPointer = function() return pointer end,
    limit = limit,

    setCallback = function (cb)
        callback = cb
    end,
    
    undo = undo,
    redo = redo,

    count = count
}