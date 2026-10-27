# 只展开当前层；子节点保留引用，递归表单进入子节点时再解析。
def resolve($root):
  def follow($seen):
    if type == "boolean" then if . then {} else error("此字段不允许设置") end
    elif has("$ref") then
      . as $s | .["$ref"] as $ref |
      if ($seen | index($ref)) != null then error("循环引用没有可编辑节点")
      elif ($ref | startswith("#/")) or $ref == "#" then
        ($root | getpath(if $ref == "#" then [] else $ref[2:] | split("/") | map(gsub("~1";"/") | gsub("~0";"~")) end)) as $target |
        if $target == null then error("引用不存在") else
          ($target | follow($seen + [$ref])) * ($s | del(.["$ref"]))
        end
      else error("不支持外部 schema 引用") end
    else . end;
  follow([]);

def merge_schema($a; $b):
  ($a * $b) + {
    properties: (reduce ((($a.properties // {}) + ($b.properties // {})) | keys_unsorted[]) as $k ({};
      .[$k] = (if ($a.properties | has($k)) and ($b.properties | has($k)) then
        {allOf: [$a.properties[$k], $b.properties[$k]]}
        else ($b.properties[$k] // $a.properties[$k]) end))),
    required: ((($a.required // []) + ($b.required // [])) | unique)
  };

def variants($root):
  resolve($root) as $s |
  (reduce ($s.allOf // [])[] as $part ([$s | del(.allOf, .oneOf, .anyOf)];
    [ .[] as $left | ($part | variants($root))[] | merge_schema($left; .) ])) as $base |
  if ($s | has("oneOf")) or ($s | has("anyOf")) then
    [$base[] as $left | ($s.oneOf // $s.anyOf)[] | variants($root)[] | merge_schema($left; .)]
  elif ($s.type | type) == "array" then
    [$base[] as $left | $s.type[] | $left + {type: .}]
  else $base end;

def kind:
  if .type then .type elif has("const") then (.const | type)
  elif .enum then (.enum[0] | type)
  elif has("items") then "array" elif has("properties") or has("additionalProperties") then "object"
  else "string" end;

def discriminator_match($root; $data; $ignore):
  . as $s | all(($s.properties // {} | to_entries[]) ;
    .key as $k | (.value | resolve($root)) as $p |
    if $k == $ignore or ($data | type) != "object" or ($data | has($k) | not) then true
    elif $p | has("const") then $data[$k] == $p.const
    elif $p | has("enum") then ($p.enum | index($data[$k])) != null
    else true end);

def scalar_valid($root; $v):
  resolve($root) as $s |
  (($s | has("const") | not) or $v == $s.const) and
  (($s | has("enum") | not) or ($s.enum | index($v)) != null) and
  (if $s.type == null then true else
    (if ($s.type | type) == "array" then $s.type else [$s.type] end) |
    any(.[]; . == ($v | type) or (. == "integer" and ($v | type) == "number" and $v == ($v | floor))) end) and
  (if ($v | type) == "number" then
    ($s.minimum == null or $v >= $s.minimum) and ($s.maximum == null or $v <= $s.maximum) and
    ($s.exclusiveMinimum == null or $v > $s.exclusiveMinimum) and ($s.exclusiveMaximum == null or $v < $s.exclusiveMaximum) and
    ($s.multipleOf == null or ($v / $s.multipleOf | . == floor))
  elif ($v | type) == "string" then
    ($s.minLength == null or ($v | length) >= $s.minLength) and
    ($s.maxLength == null or ($v | length) <= $s.maxLength) and
    ($s.pattern == null or ($v | test($s.pattern)))
  else true end) and
  all(($s.allOf // [])[]; scalar_valid($root; $v)) and
  (if $s.anyOf then any($s.anyOf[]; scalar_valid($root; $v)) else true end) and
  (if $s.oneOf then ([ $s.oneOf[] | select(scalar_valid($root; $v)) ] | length) == 1 else true end);

def parse_scalar($root; $text; $current):
  . as $s | variants($root) |
  sort_by(if kind == ($current | type) then 0 else 1 end) |
  [ .[] | kind as $k |
    (if $k == "string" then $text
     elif $k == "boolean" then
       if ["on","true","enable"] | index($text | ascii_downcase) then true
       elif ["off","false","disable"] | index($text | ascii_downcase) then false else empty end
     elif $k == "null" then if $text == "null" then null else empty end
     elif $k == "number" or $k == "integer" then
       try ($text | fromjson | select(type == "number")) catch empty
     else empty end) as $v | select($s | scalar_valid($root; $v)) | $v ] |
  if length == 0 then error("字段值不是允许的标量或超出范围") else .[0] end;

# 设置判别字段时允许寻找新分支；其他路径遵循已配置的判别字段。
def field_node($root; $data; $path):
  if ($path | length) == 0 then . else
    $path[0] as $key |
    [variants($root)[] | select(discriminator_match($root; $data; $key)) |
      select((.properties // {}) | has($key)) | .properties[$key] |
      field_node($root; (if ($data | type) == "object" then $data[$key] else null end); $path[1:])] |
    if length == 0 then error("字段路径不存在或不是已知对象字段")
    elif length == 1 then .[0] else {anyOf: unique} end
  end;

def redact:
  if type == "object" then with_entries(if .key == "private_key" then .value = "<已隐藏>" else .value |= redact end)
  elif type == "array" then map(redact) else . end;
