# 编码遵循已部署客户端的分享线格式；字段来自当前配置。
def enc: tostring | @uri;
def b64url: @base64 | gsub("\\+";"-") | gsub("/";"_") | sub("=+$";"");
def authority($h; $p): (if $h|contains(":") then "[" + ($h|ltrimstr("[")|rtrimstr("]")) + "]" else $h end) + ":" + ($p|tostring);
def query: to_entries | map(select(.value != null and (.value != "" or .key == "sid" or .key == "eh")) | (.key|enc)+"="+(.value|enc)) | join("&");
def first_value: if type == "array" then .[0] else . end;
def required($v; $name): if $v == null or $v == "" then error("缺少分享字段："+$name) else $v end;
. as $v | .inbound as $n | (.user // {}) as $u |
required(.host; "服务器地址") as $h | required(.port; "端口") as $p |
authority($h; $p) as $a | ($n.tag // $n.type | enc) as $tag |
($n.transport // {}) as $t |
(if .front != null then "tls" elif $n.tls.enabled != true then "none" elif $n.tls.reality.enabled == true then "reality" else "tls" end) as $security |
($n.tls.server_name // "" | if length>0 then . else $v.tls_domain // ($n.tls.acme.domain|first_value) // $n.tls.reality.handshake.server // $v.front.host // $h end) as $sni |
({security:$security, sni:(if $security != "none" then $sni else null end),
 alpn:($n.tls.alpn // [] | if type == "array" then join(",") else . end),
 type:(if $n.type=="vless" and $t.type=="http" then "h2" else $t.type // "tcp" end), path:($v.front.path // $t.path),
 host:(($t.host|first_value) // $t.headers.Host // $t.headers.host // $v.front.host),
 flow:$u.flow,
 pbk:(if $security == "reality" then required($v.public_key;"Reality 公钥") else null end),
 sid:(if $security == "reality" then ($n.tls.reality.short_id|first_value) // "" else null end),
 fp:(if $security == "reality" then "chrome" else null end),
 ed:$t.max_early_data,
 eh:$t.early_data_header_name,
 allowInsecure:(if $v.selfsigned then 1 else null end),serviceName:$t.service_name}) as $q |
if $n.type == "vmess" then
  "vmess://"+({v:"2",ps:($n.tag // "vmess"),add:$h,port:($p|tostring),id:required($u.uuid;"UUID"),aid:($u.alterId // 0),
    net:($t.type // "tcp" | if .=="http" then "h2" else . end),type:"none",host:($q.host // ""),path:($q.path // ""),
    tls:(if $security=="none" then "" else "tls" end),sni:$q.sni,alpn:$q.alpn,ed:$q.ed,eh:$q.eh,allowInsecure:$q.allowInsecure}
    | with_entries(select(.value!=null)) | tojson | @base64)
elif $n.type == "vless" then
  "vless://"+(required($u.uuid;"UUID")|enc)+"@"+$a+"?"+($q+{encryption:"none"}|query)+"#"+$tag
elif $n.type == "trojan" then "trojan://"+(required($u.password;"密码")|enc)+"@"+$a+"?"+($q|query)+"#"+$tag
elif $n.type == "shadowsocks" or $n.type == "shadowtls" then
  (if $n.type == "shadowtls" then required($v.inner;"ShadowTLS 内层") else $n end) as $ss |
  (if $n.type == "shadowtls" then ($v.inner_user // {}) else $u end) as $su |
  required($ss.method;"加密方法") as $method |
  (required($ss.password;"SS 密码") + (if $su.password != null then ":"+$su.password else "" end)) as $pass |
  "ss://"+($method+":"+$pass|b64url)+"@"+$a+
  (if $n.type == "shadowtls" then
    "/?shadow-tls=" + ({version:($n.version // 1|tostring),host:$n.handshake.server,password:required(($u.password // $n.password);"ShadowTLS 密码")}|tojson|@base64|enc)
   else "" end)+"#"+$tag
elif $n.type == "socks" then
  "socks://"+(if $u.username != null then ($u.username+":"+($u.password // "")|@base64)+"@" else "" end)+$a+"#"+$tag
elif $n.type == "tuic" then
  "tuic://"+(required($u.uuid;"UUID")|enc)+":"+(required($u.password;"密码")|enc)+"@"+$a+"?"+({sni:$sni,alpn:($n.tls.alpn // []|join(",")),congestion_control:$n.congestion_control,allow_insecure:(if $v.selfsigned then 1 else null end)}|query)+"#"+$tag
elif $n.type == "hysteria2" or $n.type == "anytls" then
  $n.type+"://"+(required($u.password;"密码")|enc)+"@"+$a+"/?"+({sni:$sni,obfs:$n.obfs.type,"obfs-password":$n.obfs.password,insecure:(if $v.selfsigned then 1 else null end),allowInsecure:(if $v.selfsigned and $n.type=="anytls" then 1 else null end),pinSHA256:(if $n.type=="hysteria2" then $v.cert_pin else null end)}|query)+"#"+$tag
else error("此协议没有已知分享格式") end
