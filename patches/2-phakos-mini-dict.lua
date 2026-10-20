--[[
phakOS: minimal dictionary popup.

Replaces KOReader's large DictQuickLookup window for word lookups from the
reader (long-press on a word) with a small, borderless-ish box placed next to
the word, sized to the definition, with small text and no buttons.

Why: DictQuickLookup shows itself with "flashui", which the phakOS
framebuffer backend (ffi/framebuffer_phakos.lua) turns into a FULL-screen
GC16 refresh, and it is ~90% of the screen wide and ~35% high. This popup only
asks for "ui" (partial) refreshes of its own rectangle. The backend refreshes
full-width bands, so the popup is kept as SHORT as possible (max 25% of the
screen height) - height is what costs.

Gestures while it is open:
  tap inside      -> next dictionary result (wraps around)
  hold inside     -> open the normal KOReader dictionary window
  tap/hold/swipe outside, Back key -> close

Settings (settings.reader.lua, optional):
  phakos_mini_dict = false            -- disable, use the stock window
  phakos_mini_dict_font_size = 14     -- definition font size
  phakos_mini_dict_max_width = 0.45   -- fraction of screen width
  phakos_mini_dict_max_height = 0.25  -- fraction of screen height

Installed to <koreader>/patches/ (late "2-" priority, applied after the UI
manager is ready). Delete the file to restore stock behaviour.
]]
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local MiniDict = InputContainer:extend{
    name = "phakos_mini_dict",
    word = nil,
    results = nil,
    word_boxes = nil,
    highlight = nil,
    dialog = nil,
    rd = nil, -- ReaderDictionary instance
    link = nil,
    dict_close_callback = nil,
    index = 1,
}

-- Plain, compact text for one result.
local function plainDefinition(result)
    local def = result.definition or ""
    if result.is_html then
        def = util.htmlToPlainText(def)
    end
    def = def:gsub("\r", "")
    def = def:gsub("^[\n%s]+", ""):gsub("[\n%s]+$", "")
    -- StarDict entries (JMdict) repeat the headword as their first line.
    local first, rest = def:match("^([^\n]*)\n(.*)$")
    if first and result.word and util.trim(first) == util.trim(result.word) then
        def = rest
    end
    def = def:gsub("\n%s*\n+", "\n")
    return def
end

function MiniDict:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.ges_events = {
        MiniDictTap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
        MiniDictHold = { GestureRange:new{ ges = "hold", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
        MiniDictSwipe = { GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- union of the looked-up word's boxes (screen coordinates)
    for _, b in ipairs(self.word_boxes or {}) do
        self.word_rect = self.word_rect and self.word_rect:combine(b) or Geom:new{ x = b.x, y = b.y, w = b.w, h = b.h }
    end
    self:build()
end

function MiniDict:freeFrame()
    if self.frame then
        self.frame:free()
        self.frame = nil
    end
end

function MiniDict:build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local result = self.results[self.index]
    local font_size = G_reader_settings:readSetting("phakos_mini_dict_font_size") or 14
    local face = Font:getFace("cfont", font_size)
    local border = Size.border.thin
    local pad = Size.padding.small
    local gap = Size.padding.default
    local margin = Size.margin.small
    local chrome = 2 * (border + pad)
    local max_w = math.floor(sw * (G_reader_settings:readSetting("phakos_mini_dict_max_width") or 0.45)) - chrome
    local max_h = math.floor(sh * (G_reader_settings:readSetting("phakos_mini_dict_max_height") or 0.25)) - chrome

    local head = result.word or self.word or ""
    if #self.results > 1 then
        head = head .. "  " .. self.index .. "/" .. #self.results
    end
    local def = plainDefinition(result)

    -- Shrink-to-fit width: widest of the headword and the (first) lines.
    local natural = 0
    local probe = TextWidget:new{ text = head, face = face, bold = true }
    natural = probe:getSize().w
    probe:free()
    local nlines = 0
    for line in (def .. "\n"):gmatch("([^\n]*)\n") do
        nlines = nlines + 1
        if nlines > 12 or natural >= max_w then break end
        probe = TextWidget:new{ text = line, face = face }
        natural = math.max(natural, probe:getSize().w)
        probe:free()
    end
    local content_w = math.max(Screen:scaleBySize(60), math.min(max_w, natural + 1))

    local head_widget = TextWidget:new{
        text = head,
        face = face,
        bold = true,
        max_width = content_w,
    }
    local span = VerticalSpan:new{ width = Size.span.vertical_default }
    local def_max_h = max_h - head_widget:getSize().h - span.width
    local def_widget = TextBoxWidget:new{
        text = def,
        face = face,
        width = content_w,
    }
    if def_widget:getSize().h > def_max_h then
        def_widget:free()
        def_widget = TextBoxWidget:new{
            text = def,
            face = face,
            width = content_w,
            height = def_max_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end

    self.frame = FrameContainer:new{
        bordersize = border,
        padding = pad,
        margin = 0,
        radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            head_widget,
            span,
            def_widget,
        },
    }
    local size = self.frame:getSize()
    local w, h = size.w, size.h

    -- Placement: right of the word, else left of it, else below/above it.
    local x, y
    local r = self.word_rect
    if r then
        if r.x + r.w + gap + w <= sw - margin then
            x, y = r.x + r.w + gap, r.y
        elseif r.x - gap - w >= margin then
            x, y = r.x - gap - w, r.y
        else
            x = r.x + math.floor(r.w / 2) - math.floor(w / 2)
            if r.y + r.h + gap + h <= sh - margin then
                y = r.y + r.h + gap
            else
                y = r.y - gap - h
            end
        end
    else
        x, y = math.floor((sw - w) / 2), math.floor((sh - h) / 2)
    end
    x = math.max(margin, math.min(x, sw - margin - w))
    y = math.max(margin, math.min(y, sh - margin - h))
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
end

function MiniDict:paintTo(bb, x, y)
    self.frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

function MiniDict:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function MiniDict:onCloseWidget()
    self:freeFrame()
end

-- Refresh only `region` of the page underneath (repaint is in RAM; the
-- panel update is a partial band covering just this region).
function MiniDict:refreshUnder(region)
    if self.dialog then
        UIManager:setDirty(self.dialog, function() return "ui", region end)
    end
end

function MiniDict:nextResult()
    if #self.results < 2 then return end
    local old = self.dimen
    self:freeFrame()
    self.index = self.index % #self.results + 1
    self:build()
    -- page under the old box, then us on top (UIManager repaints upward)
    self:refreshUnder(old:combine(self.dimen))
    UIManager:setDirty(self, function() return "ui", old:combine(self.dimen) end)
end

function MiniDict:close(keep_highlight)
    local region = self.dimen
    if self.word_rect then region = region:combine(self.word_rect) end
    UIManager:close(self)
    if self.highlight and not keep_highlight then
        -- ReaderHighlight:clear() marks the whole reader dirty with no
        -- region (= full-screen band). Clamp that to our region.
        local dialog = self.dialog
        local orig = UIManager.setDirty
        UIManager.setDirty = function(um, widget, refreshtype, refreshregion, ...)
            if widget == dialog and refreshtype == "ui" and refreshregion == nil then
                return orig(um, widget, "ui", region)
            end
            return orig(um, widget, refreshtype, refreshregion, ...)
        end
        local ok, err = pcall(self.highlight.clear, self.highlight)
        UIManager.setDirty = orig
        if not ok then logger.warn("phakos mini dict: highlight clear failed", err) end
    end
    self:refreshUnder(region)
    if self.dict_close_callback and not keep_highlight then
        self.dict_close_callback()
    end
end

function MiniDict:onMiniDictTap(_, ges)
    if not ges.pos:notIntersectWith(self.dimen) then
        self:nextResult()
    else
        self:close()
    end
    return true
end

function MiniDict:onMiniDictHold(_, ges)
    if not ges.pos:notIntersectWith(self.dimen) then
        -- escape hatch: the full stock window (buttons, search, wiki...)
        self:close(true)
        local rd = self.rd
        rd._phakos_full_once = true
        rd:showDict(self.word, self.results, self.word_boxes, self.link, self.dict_close_callback)
    else
        self:close()
    end
    return true
end

function MiniDict:onMiniDictSwipe()
    self:close()
    return true
end

function MiniDict:onClose()
    self:close()
    return true
end

if ReaderDictionary._phakos_mini_dict_installed then
    logger.info("phakos: minimal dictionary popup already installed")
    return
end
local orig_showDict = ReaderDictionary.showDict
ReaderDictionary.showDict = function(self, word, results, boxes, link, dict_close_callback)
    local use_mini = results and results[1] and boxes and boxes[1]
        and not self.is_wiki
        and not self._phakos_full_once
        and G_reader_settings:nilOrTrue("phakos_mini_dict")
    self._phakos_full_once = nil
    if not use_mini then
        return orig_showDict(self, word, results, boxes, link, dict_close_callback)
    end
    self:dismissLookupInfo()
    local ok, popup = pcall(MiniDict.new, MiniDict, {
        rd = self,
        word = word,
        results = results,
        word_boxes = boxes,
        link = link,
        highlight = self.highlight,
        dialog = self.dialog,
        dict_close_callback = dict_close_callback,
    })
    if not ok then
        logger.warn("phakos mini dict failed, using stock window:", popup)
        return orig_showDict(self, word, results, boxes, link, dict_close_callback)
    end
    UIManager:show(popup)
end

ReaderDictionary._phakos_mini_dict_installed = true
logger.info("phakos: minimal dictionary popup patch loaded")
