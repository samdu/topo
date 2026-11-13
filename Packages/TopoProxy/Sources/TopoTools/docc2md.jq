# docc2md.jq — Apple DocC render JSON → Markdown.
# usage: jq -r -f docc2md.jq page.json
# The input is what developer.apple.com/tutorials/data/documentation/<path>.json answers.

def base: "https://developer.apple.com";

# A reference id → its record from the page's reference table.
. as $page | .references as $refs |
def ref($id): ($refs[$id] // {});

# What the converter has no rendering for is said, never dropped: one line naming its type.
def unrendered($what): "[apple-doc: unrendered \(.type // .kind // "?") \($what)]";

# Blank lines off both ends.
def trimmed: until(length == 0 or .[0] != ""; .[1:]) | until(length == 0 or .[-1] != ""; .[:-1]);

def href($r):
  ($r.url // "") as $u
  | if ($u | startswith("/")) then base + $u else $u end;

# Inline content → one string.
def inl:
  if type == "array" then map(inl) | join("")
  elif type == "string" then .
  elif type != "object" then ""
  else
    .type as $t
    | if   $t == "text"        then .text
      elif $t == "codeVoice"   then "`" + .code + "`"
      elif $t == "emphasis"    then "*" + (.inlineContent | inl) + "*"
      elif $t == "strong"      then "**" + (.inlineContent | inl) + "**"
      elif $t == "newTerm"     then "*" + (.inlineContent | inl) + "*"
      elif $t == "inlineHead"  then "**" + (.inlineContent | inl) + "**"
      elif $t == "strikethrough" then "~~" + (.inlineContent | inl) + "~~"
      elif $t == "subscript" or $t == "superscript" then (.inlineContent | inl)
      elif $t == "reference"   then
             ref(.identifier) as $r
             | (.overridingTitle // $r.title // (.identifier | sub(".*/";""))) as $title
             | if ($r.url // "") == "" then "`" + $title + "`"
               elif ($r.role // "") == "symbol" or ($r.kind // "") == "symbol"
               then "[`" + $title + "`](" + href($r) + ")"
               else "[" + $title + "](" + href($r) + ")" end
      elif $t == "link"        then "[" + ((.title // .destination) | if type=="array" then inl else . end) + "](" + .destination + ")"
      elif $t == "image"       then ref(.identifier) as $r | "![" + ($r.alt // "image") + "](" + (($r.variants[0].url // "") | if startswith("/") then base + . else . end) + ")"
      elif has("inlineContent") then unrendered("inline") + " " + (.inlineContent | inl)
      else unrendered("inline") end
  end;

# A code listing's lines carry this mark until the end, so the blank lines between blocks are
# collapsed without touching a listing's own.
def code_mark: "\u0001";

# A list item from its blocks: the marker, with a lead paragraph beside it, then the rest of the
# lines hung under it by $n; render is the block renderer. A lead that is any other block — a
# heading, a list, a listing, a table, an aside — starts on a line of its own below the marker,
# so it stays that block.
def item($marker; $n; render):
  def hung: map(if . == "" then . else (" " * $n) + . end);
  (((.[0].type // "") == "paragraph") and ((.[0] | render)[0] != "")) as $lead
  | (render | trimmed) as $lines
  | if ($lines | length) == 0 then [ $marker ]
    elif $lead then [ $marker + " " + $lines[0] ] + ($lines[1:] | hung)
    else [ $marker ] + ($lines | hung) end;

# Block content → markdown lines (array of strings). $d is the list depth.
def blk($d):
  ("  " * $d) as $pad
  | if type == "array" then map(blk($d)) | add // []
    elif type != "object" then []
    else
      .type as $t
      | if   $t == "paragraph"   then [ (.inlineContent | inl) ]
        elif $t == "heading"     then [ ("#" * (.level // 2)) + " " + (.text // (.inlineContent | inl)) ]
        elif $t == "codeListing" then [ "```" + (.syntax // "") ] + ((.code // []) | map(code_mark + .)) + [ "```" ]
        elif $t == "aside"       then
               [ "> **" + (.name // (.style // "Note") | ascii_upcase[0:1] + .[1:]) + "**" ]
               + ((.content // []) | blk(0) | trimmed | map(if . == "" then ">" else "> " + . end))
        elif $t == "unorderedList" then
               [ (.items // [])[] | (.content | blk($d + 1)) | (.[0] |= ($pad + "- " + .)) | .[1:] |= map(if . == "" then . else "  " + . end) | .[] ]
        elif $t == "orderedList" then
               (.start // 1) as $start
               | [ (.items // []) | to_entries[] | .key as $i | (.value.content | blk($d + 1)) | (.[0] |= ($pad + (($start + $i) | tostring) + ". " + .)) | .[1:] |= map(if . == "" then . else "   " + . end) | .[] ]
        elif $t == "termList"    then
               [ (.items // [])[] | ("- **" + (.term.inlineContent | inl) + "**:") as $marker
                 | (.definition.content // []) | item($marker; 2; blk(0)) | .[] ]
        elif $t == "table"       then
               (.rows // []) as $rows
               | if ($rows | length) == 0 then []
                 else
                   ($rows | map(map(blk(0) | map(select(. != "")) | join(" ") | gsub("\\|"; "\\|")))) as $cells
                   | ($cells | map(length) | max) as $n
                   | if .header == "row" or .header == "both" then
                       [ "| " + ($cells[0] | join(" | ")) + " |",
                         "|" + ([range($n)] | map("---") | join("|")) + "|" ]
                       + ($cells[1:] | map("| " + join(" | ") + " |"))
                     else
                       [ "|" + ([range($n)] | map("  ") | join("|")) + "|",
                         "|" + ([range($n)] | map("---") | join("|")) + "|" ]
                       + ($cells | map("| " + join(" | ") + " |"))
                     end
                 end
        elif $t == "image"       then [ ({type:"image", identifier:.identifier} | inl) ]
        elif $t == "video"       then [ "(video: " + (ref(.identifier).alt // .identifier) + ")" ]
        elif $t == "links"       then [ (.items // [])[] | ref(.) as $r | "- [" + ($r.title // .) + "](" + href($r) + ")" + (if ($r.abstract // []) | length > 0 then ": " + ($r.abstract | inl) else "" end) ]
        elif $t == "row"         then [ (.columns // [])[] | .content | blk($d) | .[] ]
        elif $t == "tabNavigator" then [ (.tabs // [])[] | ("**" + .title + "**"), (.content | blk($d) | .[]) ]
        elif $t == "small"       then [ (.inlineContent | inl) ]
        elif $t == "thematicBreak" then [ "---" ]
        elif $t == "dictionaryExample" then [ (.summary // [] | blk($d) | .[]), "```json", (.example.code // [] | .[]), "```" ]
        elif has("content")      then [ unrendered("block") ] + (.content | blk($d))
        elif has("inlineContent") then [ unrendered("block"), (.inlineContent | inl) ]
        else [ unrendered("block") ] end
      | . + [ "" ]
    end;


# A list of identifiers → bullet lines with title, link and abstract.
def idlist($ids):
  [ ($ids // [])[] | ref(.) as $r
    | select($r != {})
    | "- " + (if ($r.role // $r.kind // "") == "symbol" then "[`" + $r.title + "`]" else "[" + $r.title + "]" end)
          + "(" + href($r) + ")"
          + (if ($r.deprecated // false) then " *(deprecated)*" else "" end)
          + (if (($r.abstract // []) | length) > 0 then ": " + ($r.abstract | inl) else "" end) ];

def platforms:
  [ (.metadata.platforms // [])[]
    | .name + (if .introducedAt then " " + .introducedAt else "" end)
           + (if .beta then " beta" else "" end)
           + (if .deprecatedAt then ", deprecated " + .deprecatedAt elif .deprecated then ", deprecated" else "" end)
           + (if .unavailable then ", unavailable" else "" end) ]
  | if length > 0 then "Availability: " + join(" · ") else empty end;

# One of the page's primary content sections → its lines, each kind as DocC names it; a kind
# with no rendering here is one marker line.
def section:
  .kind as $k
  | if $k == "declarations" then
      [ .declarations[]? | "```" + ((.languages // ["swift"])[0]), (.tokens | map(.text) | join("")), "```", "" ]
    elif $k == "content" then (.content // []) | blk(0)
    elif $k == "parameters" then
      [ "## Parameters", "" ]
      + [ (.parameters // [])[] | ("- **" + .name + "**:") as $marker | (.content // []) | item($marker; 2; blk(0)) | .[] ]
      + [ "" ]
    elif $k == "returnValue" then [ "## Return Value", "" ] + ((.content // []) | blk(0))
    elif $k == "discussion" then [ "## Discussion", "" ] + ((.content // []) | blk(0))
    elif $k == "possibleValues" then
      [ "## " + (.title // "Possible Values"), "" ]
      + [ (.values // [])[] | .name as $name | (.content // [])
          | item("- `" + $name + "`" + (if (blk(0) | trimmed | length) > 0 then ":" else "" end); 2; blk(0)) | .[] ]
      + [ "" ]
    elif $k == "mentions" then [ "## Mentioned in", "" ] + idlist(.mentions) + [ "" ]
    elif $k == "restEndpoint" then
      [ "## " + (.title // "URL"), "", "```", ((.tokens // []) | map(.text) | join("")), "```", "" ]
    else [ unrendered("section"), "" ] end;

def id_sections($secs; $heading):
  [ ($secs // [])[] | select((.identifiers // []) | length > 0) ] as $kept
  | if ($kept | length) == 0 then []
    else [ "## " + $heading, "" ]
      + [ $kept[] | ("### " + .title), "", (idlist(.identifiers) | .[]), "" ]
    end;

def breadcrumb:
  [ (.hierarchy.paths[0] // [])[] | ref(.) | select(. != {}) | .title ] | if length > 0 then join(" › ") else empty end;

.
| [
    "# " + (.metadata.title // "Untitled"),
    (if .metadata.roleHeading then "*" + .metadata.roleHeading + "*" else empty end),
    (breadcrumb),
    (platforms),
    "Source: " + base + ($page.variants[0].paths[0] // ($page.identifier.url // "" | sub("^doc://[^/]*"; "") | ascii_downcase)),
    "",
    (if (.abstract // []) | length > 0 then (.abstract | inl), "" else empty end)
  ]
  + (if (.deprecationSummary // []) | length > 0
     then [ "> **Deprecated**" ] + (.deprecationSummary | blk(0) | trimmed | map(if . == "" then ">" else "> " + . end)) + [ "" ]
     else [] end)
  + [ (.primaryContentSections // [])[] | section | .[] ]
  + id_sections(.topicSections; "Topics")
  + id_sections(.relationshipsSections // .relationshipSections; "Relationships")
  + id_sections(.seeAlsoSections; "See Also")
| map(select(. != null))
| reduce .[] as $line ([]; if $line == "" and (length > 0) and (.[-1] == "") then . else . + [$line] end)
| map(gsub(code_mark; ""))
| join("\n")
