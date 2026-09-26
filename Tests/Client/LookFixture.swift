import Foundation

/// A `look.json` that names every field of `Look`, each at a value the compiled look does not
/// have. It is the fixture the coverage walk is run against — a field of the look this document
/// does not reach is a field the mind cannot reach — and the source the per-field documents in
/// the render suite are cut from.
///
/// Every value here differs from the shipped default for that field, including the four the open
/// jewel differs from the resting one in, so one slab of JSON serves both.
enum LookFixture {
    /// How many fields of the look this document sets, which is every one of them: the jewel is
    /// three fields of the look and not one, since the badge's slab and the composer's open one
    /// are stones of their own. It is the count the reader answers with, so a compound — a
    /// shadow, a size, a font — is one.
    static let fields = 183

    static let full = """
    {
      "transcript": {
        "spacing": 20,
        "captionSpacing": 7,
        "horizontalPadding": 24,
        "maximumLineWidth": "infinity",
        "replyTrailingInset": 40,
        "personLeadingInset": 30,
        "bodyFont": { "style": "largeTitle", "weight": "black" },
        "labelFont": { "style": "title", "weight": "light" },
        "noticeFont": { "size": 31, "weight": "heavy" },
        "text": ["#101010", "#F0F0F0"],
        "caption": ["#202020", "#E0E0E0"]
      },
      "markdown": {
        "blockSpacing": 13,
        "listIndent": 27,
        "markerSpacing": 9,
        "heading1Font": { "style": "largeTitle", "weight": "heavy" },
        "heading2Font": { "size": 33, "weight": "light" },
        "heading3Font": { "style": "caption", "weight": "black" },
        "codeFont": { "size": 19, "weight": "medium" },
        "codeInk": ["#123456", "#654321"],
        "codeBlock": {
          "accent": ["#AB0000", "#00AB00"],
          "fillOpacity": 0.33,
          "strokeWidth": 3,
          "cornerRadius": 14,
          "horizontalPadding": 17,
          "verticalPadding": 15,
          "surface": "glass"
        },
        "codeOverflow": "wrap",
        "quoteBar": ["#00AB00", "#AB0000"],
        "quoteBarWidth": 7,
        "quoteIndent": 11,
        "quoteText": ["#330033", "#CCFFCC"],
        "marker": ["#003333", "#FFCCCC"],
        "ruleWidth": 5
      },
      "bubble": {
        "accent": ["#FF0000", "#00FF00"],
        "fillOpacity": 0.42,
        "strokeWidth": 4,
        "cornerRadius": 3,
        "horizontalPadding": 26,
        "verticalPadding": 19,
        "surface": "material"
      },
      "plain": {
        "accent": ["#0000FF", "#FFFF00"],
        "fillOpacity": 0.3,
        "strokeWidth": 2,
        "cornerRadius": 9,
        "horizontalPadding": 11,
        "verticalPadding": 7,
        "surface": "glass"
      },
      "draft": {
        "written": {
          "accent": ["#FF7700", "#0077FF"],
          "fillOpacity": 0.5,
          "strokeWidth": 5,
          "cornerRadius": 2,
          "horizontalPadding": 28,
          "verticalPadding": 21,
          "surface": "material"
        },
        "sending": {
          "accent": ["#77FF00", "#7700FF"],
          "fillOpacity": 0.55,
          "strokeWidth": 6,
          "cornerRadius": 5,
          "horizontalPadding": 30,
          "verticalPadding": 23,
          "surface": "material"
        },
        "minimumWidth": 90,
        "spacing": 17,
        "slot": 48,
        "sendFont": { "style": "footnote", "weight": "thin" },
        "sendInk": ["#AA00AA", "#00AAAA"],
        "sendRestingOpacity": 0.8
      },
      "jewel": \(jewel),
      "press": {
        "wall": 0.05,
        "shade": ["#7F0000", "#00007F"],
        "catchLight": ["#00FF7F", "#FF007F"],
        "soften": 0.9,
        "floor": 0.9
      },
      "badge": {
        "size": 56,
        "markSize": 36,
        "jewel": \(jewel)
      },
      "settings": { "tint": ["#336699", "#99CCFF"] },
      "composer": {
        "widthFraction": 0.55,
        "bottomPadding": 22,
        "horizontalInset": 30,
        "verticalInset": 14,
        "cornerRadius": 10,
        "spacing": 6,
        "surface": "flat",
        "tint": ["#B3002D", "#FF6680"],
        "tintOpacity": 0.95,
        "glow": { "color": "#20304050", "radius": 9, "x": -4, "y": 11 },
        "duration": 0.9,
        "presenceRise": 120,
        "presenceDuration": 0.7,
        "compactShare": 0.8,
        "dimmedSaturation": 2.5,
        "dimmedOpacity": 0.15,
        "flank": {
          "font": { "style": "caption2", "weight": "bold" },
          "ink": ["#0A0B0C", "#F5F4F3"],
          "openInk": ["#112233", "#332211"],
          "etchOpacity": 0.35,
          "etchLight": { "color": "#AABBCCDD", "radius": 3, "x": 1, "y": 2 },
          "etchShade": { "color": "#DDCCBBAA", "radius": 2, "x": -1, "y": -3 },
          "heldOpacity": 0.85
        },
        "well": {
          "size": 96,
          "jewelSize": 40,
          "floor": ["#123123", "#321321"],
          "bore": { "color": "#0A141E32", "radius": 11, "x": 2, "y": 9 },
          "lip": { "color": "#141E28FF", "radius": 4, "x": -2, "y": 3 },
          "catchLight": { "color": "#E6E6E64D", "radius": 6, "x": 4, "y": -6 },
          "edgeColors": ["#FF0000", "#00FF00", "#0000FF", "#FFFFFF"],
          "edgeWidth": 3
        },
        "glyph": {
          "size": 34,
          "weight": "black",
          "openCast": ["#7F00FF", "#FF7F00"]
        },
        "openJewel": \(jewel)
      },
      "mascot": {
        "scale": 2,
        "clearance": 12,
        "roamSpeed": 60,
        "roamSettle": 1.5,
        "hurry": 4,
        "frameInterval": 0.05,
        "placement": "glass",
        "pin": {"x": 0.3, "y": 0.4},
        "debug": {
          "box": "#112233",
          "reach": "#11223380",
          "room": ["#223344", "#334455"],
          "candidate": "#44556640",
          "clearing": "#55667730",
          "chosen": "#667788",
          "words": "#77889950",
          "lineWidth": 3,
          "hairline": 0.25
        }
      }
    }
    """

    /// One stone, named once and cut three times: it differs from `Look.Jewel()` in every field,
    /// and from the badge's slab and the composer's open one in the fields each of those changes,
    /// so one slab of JSON serves all three.
    private static let jewel = """
    {
        "stone": "not-a-stone",
        "cast": ["#3B0A14", "#8A1C2E"],
        "castOpacity": 0.35,
        "castBlend": "multiply",
        "bodyShade": { "color": "#11223344", "radius": 8, "x": 2, "y": -5 },
        "bodyCatch": { "color": "#55667788", "radius": 6, "x": -3, "y": 4 },
        "sheenColor": ["#123456", "#654321"],
        "sheenShadeColor": ["#ABCDEF", "#FEDCBA"],
        "sheenOpacity": 0.9,
        "sheenShadeOpacity": 0.6,
        "sheenStart": { "x": 0.1, "y": 0.4 },
        "sheenEnd": { "x": 0.9, "y": 0.2 },
        "bevelColor": ["#0F0F0F", "#F0F0F0"],
        "bevelShadeColor": ["#1F1F1F", "#E0E0E0"],
        "bevelWidth": 5,
        "bevelHighlightOpacity": 0.2,
        "bevelMidOpacity": 0.65,
        "bevelShadeOpacity": 0.05,
        "dropShadow": { "color": "#99887766", "radius": 12, "x": 5, "y": -6 }
    }
    """
}
