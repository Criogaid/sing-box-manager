#!/usr/bin/env bash
set -euo pipefail
SB_PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'status=$?; if ((status != 0)) && [[ -f $work/ui ]]; then tail -n 30 "$work/ui" >&2; fi; rm -rf -- "$work"' EXIT
SB_WORK=$work
SB_ROOT=$work/root
mkdir -p "$SB_ROOT"
source "$SB_PROJECT/lib/common.sh"
source "$SB_PROJECT/lib/forms.sh"

case ${OS:-}:$(uname -s) in Windows_NT:*|*:MINGW*|*:MSYS*)
    # 仅测试适配 Windows 原生 jq；产品运行环境是 Linux。
    jq() {
        local -a args=()
        local arg
        while (($#)); do
            arg=$1; shift
            case $arg in
                --arg|--argjson) args+=("$arg" "$1" "$2"); shift 2;;
                -L) args+=("-L" "$(cygpath -m "$1")"); shift;;
                *) if [[ -f $arg ]]; then arg=$(cygpath -m "$arg") || return; fi; args+=("$arg");;
            esac
        done
        MSYS_NO_PATHCONV=1 command jq -b "${args[@]}"
    };;
esac

check() { _forms_jq -e "$1" "$2" >/dev/null; }
reject_set() {
    cp "$work/data" "$work/before"
    if forms_set "$node" "$work/data" "$1" "$2" 2>"$work/error"; then
        printf 'Unexpected setter success: %s\n' "$1" >&2; return 1
    fi
    cmp "$work/data" "$work/before"
}
cat > "$work/schema" <<'JSON'
{"type":"object","properties":{"inbounds":{"type":"array","items":{"$ref":"#/$defs/Inbound"}},"dns":{"$ref":"#/$defs/DNS"}},"$defs":{
"Inbound":{"oneOf":[{"type":"object","properties":{"type":{"const":"alpha"},"port":{"type":"integer"}}},{"type":"object","properties":{"type":{"enum":["beta","gamma"]},"label":{"type":"string"}}}]},
"DNSServer":{"oneOf":[{"type":"object","properties":{"type":{"const":"udp"}}},{"type":"object","properties":{"type":{"const":"local"}}}]},
"DNS":{"type":"object","properties":{"servers":{"type":"array","items":{"$ref":"#/$defs/DNSServer"}}}},
"Tree":{"type":"object","properties":{"value":{"type":"integer"},"child":{"$ref":"#/$defs/Tree"}}},
"Escaped/Name":{"type":"boolean"}
}}
JSON
cat > "$work/core" <<'SH'
#!/usr/bin/env bash
[[ $# == 3 && $1 == schema && $2 == -o && $3 == "$SB_WORK"/value.* ]] || exit 9
printf 'called\n' >> "$SB_WORK/calls"
cat "$SB_WORK/schema" > "$3"
SH
chmod +x "$work/core"
export SB_WORK
SB_CORE=$work/core
forms_init
forms_init
[[ $(wc -l < "$work/calls") == 1 ]]
unset SB_SCHEMA
forms_definition DNS > "$work/definition"
forms_definition DNS > "$work/definition"
[[ $(wc -l < "$work/calls") == 1 ]]
forms_init
[[ $(forms_types Inbound | paste -sd , -) == alpha,beta,gamma ]]
[[ $(forms_types DNSServer | paste -sd , -) == local,udp ]]
forms_definition Config > "$work/definition"
check '(.properties | keys) == ["dns","inbounds"]' "$work/definition"
forms_definition Inbound beta > "$work/definition"
check '.properties.type.enum == ["beta","gamma"]' "$work/definition"
node='{"type":"object","properties":{"count":{"type":"integer","minimum":0,"maximum":10},"ratio":{"type":"number"},"flag":{"type":"boolean"},"name":{"type":"string"},"nil":{"type":["null","string"]},"nested":{"$ref":"#/$defs/Tree"},"choice":{"anyOf":[{"type":"integer"},{"type":"string"}]},"both":{"allOf":[{"type":"integer","minimum":2},{"maximum":5}]},"escaped":{"$ref":"#/$defs/Escaped~1Name"}}}'
printf '{}\n' > "$work/data"
forms_set "$node" "$work/data" count 7
forms_set "$node" "$work/data" ratio 1.25
forms_set "$node" "$work/data" flag enable
forms_set "$node" "$work/data" name '/one two'
forms_set "$node" "$work/data" nil null
forms_set "$node" "$work/data" nested.child.child.value 4
forms_set "$node" "$work/data" choice 42
forms_set "$node" "$work/data" both 3
forms_set "$node" "$work/data" escaped off
check '. == {count:7,ratio:1.25,flag:true,name:"/one two",nil:null,nested:{child:{child:{value:4}}},choice:42,both:3,escaped:false}' "$work/data"
for value in -1 11 1.5 '{}' '[]' null; do reject_set count "$value"; done
reject_set flag yes
reject_set missing value
reject_set nested.unknown value
reject_set both 1
reject_set both 6
forms_set "$node" "$work/data" flag disable
check '.flag == false' "$work/data"

node=$(forms_definition Inbound)
printf '{"type":"alpha","port":123,"unknown":false}\n' > "$work/data"
forms_set "$node" "$work/data" type beta
forms_set "$node" "$work/data" label hello
check '. == {type:"beta",port:123,unknown:false,label:"hello"}' "$work/data"
reject_set port 9
reject_set type unsupported

# 空输入、出错、取消均保留原始字节；成功完成也不填充可选默认值。
node='{"type":"object","properties":{"a":{"type":"integer"},"optional":{"type":["null","string"],"default":null},"mode":{"type":"string","enum":["a","b"]}}}'
printf '{ "a" : 1 }\n' > "$work/data"
cp "$work/data" "$work/before"
if forms_edit "$node" "$work/data" </dev/null 2>"$work/ui"; then exit 1; fi
cmp "$work/data" "$work/before"
# 字段 a -> 编辑 -> 输入 2 -> 顶层 EOF。
if forms_edit "$node" "$work/data" <<< $'3\n1\n2' 2>"$work/ui"; then exit 1; fi
cmp "$work/data" "$work/before"
if forms_edit "$node" "$work/data" <<< $'3\n1\ninvalid' 2>"$work/ui"; then exit 1; fi
cmp "$work/data" "$work/before"
forms_edit "$node" "$work/data" <<< '1' 2>"$work/ui"
check '. == {a:1}' "$work/data"
forms_edit "$node" "$work/data" <<< $'3\n1\n2\n1' 2>"$work/ui"
check '. == {a:2}' "$work/data"

# allOf 的对象字段合并后仍可逐个编辑。
node='{"allOf":[{"type":"object","properties":{"first":{"type":"integer"}}},{"type":"object","properties":{"second":{"type":"boolean"}}}]}'
printf '{}\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'3\n1\n8\n4\n1\noff\n1' 2>"$work/ui"
check '. == {first:8,second:false}' "$work/data"

# 真实递归节点经菜单进入 child，再编辑 value。
node='{"$ref":"#/$defs/Tree"}'
printf '{"value":1,"child":{"value":2}}\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'3\n1\n4\n1\n9\n1\n1' 2>"$work/ui"
check '. == {value:1,child:{value:9}}' "$work/data"

# 联合类型切换保留旧的非判别字段。
node=$(forms_definition Inbound)
printf '{"type":"alpha","port":99}\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'2\n1\n1' 2>"$work/ui"
check '. == {type:"beta",port:99}' "$work/data"
forms_edit "$node" "$work/data" <<< $'2\n4\n1\n100\n1' 2>"$work/ui"
check '. == {type:"beta",port:100}' "$work/data"
node='{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]}'
printf '"scalar"\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'2\n2\nitem\n1' 2>"$work/ui"
check '. == ["item"]' "$work/data"
forms_edit "$node" "$work/data" <<< $'1\nback' 2>"$work/ui"
check '. == "back"' "$work/data"

node='{"type":"object","additionalProperties":{"type":"array","items":{"type":"boolean"}}}'
printf '{}\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'2\nx.y\n2\non\n1\n1' 2>"$work/ui"
check '. == {"x.y":[true]}' "$work/data"
forms_edit "$node" "$work/data" <<< $'3\n2\n1' 2>"$work/ui"
check '. == {}' "$work/data"

printf '{"tls":{"private_key":"secret\\nsecond","enabled":false},"unknown":{"values":[null,1,"line\\nnext"]},"empty":{}}\n' > "$work/data"
forms_show "$work/data" > "$work/shown"
! _forms_jq -Rs -e 'contains("secret") or contains("second")' "$work/shown" >/dev/null
[[ $(wc -l < "$work/shown") == 6 ]]
node='{"type":"object","properties":{"tls":{"type":"object","properties":{"private_key":{"type":"string"}}}}}'
forms_edit "$node" "$work/data" <<< '1' 2>"$work/ui"
! _forms_jq -Rs -e 'contains("secret") or contains("second")' "$work/ui" >/dev/null

# 同类型版本仍保留可选分支，并只更新版本判别字段。
_forms_jq '."$defs".Inbound.oneOf[0].properties.version = {const:1} | ."$defs".Inbound.oneOf += [{type:"object",properties:{type:{const:"alpha"},version:{const:2},label:{type:"string"},optional_mode:{enum:["x","y"]},optional_null:{const:null,default:null}}}]' "$SB_SCHEMA" > "$work/versions"
SB_SCHEMA=$work/versions
node=$(forms_definition Inbound alpha)
_forms_jq -en --argjson node "$node" '$node.oneOf | length == 2' >/dev/null
printf '{"type":"alpha","version":1,"port":77}\n' > "$work/data"
forms_edit "$node" "$work/data" <<< $'2\n1' 2>"$work/ui"
check '. == {type:"alpha",version:2,port:77}' "$work/data"

if [[ -n ${TEST_CORE:-} ]]; then
    SB_CORE=$TEST_CORE
    SB_WORK=$work/real
    mkdir -p "$SB_WORK"
    unset SB_SCHEMA
    forms_init
elif [[ -n ${TEST_SCHEMA:-} ]]; then SB_SCHEMA=$TEST_SCHEMA; fi
if [[ -n ${TEST_SCHEMA:-}${TEST_CORE:-} ]]; then
    forms_types Inbound > "$work/types"
    [[ $(wc -l < "$work/types") -gt 10 ]]
    forms_types DNSServer > "$work/types"
    [[ $(wc -l < "$work/types") -gt 10 ]]
    for definition in Inbound DNSServer; do
        while IFS= read -r protocol; do
            forms_definition "$definition" "$protocol" > "$work/definition"
            check 'type == "object"' "$work/definition"
        done < <(forms_types "$definition")
    done
    node=$(forms_definition Inbound vless)
    printf '{"type":"vless","tag":"test"}\n' > "$work/data"
    forms_set "$node" "$work/data" listen_port 23456
    forms_set "$node" "$work/data" tls.enabled on
    forms_set "$node" "$work/data" tls.reality.private_key 'synthetic-key'
    check '. == {type:"vless",tag:"test",listen_port:23456,tls:{enabled:true,reality:{private_key:"synthetic-key"}}}' "$work/data"
    node=$(forms_definition DNS)
    printf '{"rules":[{"domain":"example.test","server":"kept"}]}\n' > "$work/data"
    forms_set "$node" "$work/data" disable_cache true
    check '. == {rules:[{domain:"example.test",server:"kept"}],disable_cache:true}' "$work/data"
fi
printf 'forms: all checks passed\n'
