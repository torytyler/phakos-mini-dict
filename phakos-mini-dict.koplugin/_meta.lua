local _ = require("gettext")
return {
    fullname = _("Minimal dictionary popup"),
    description = _([[
Shows dictionary lookups in a small popup placed next to the selected word instead of KOReader's large dictionary window.

Tap the popup for the next result; hold it for the full stock dictionary window. Tap outside, swipe, or press Back to close.

Settings (advanced, settings.reader.lua):
phakos_mini_dict, phakos_mini_dict_font_size, phakos_mini_dict_max_width, phakos_mini_dict_max_height.]]),
}
