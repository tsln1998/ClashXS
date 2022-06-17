#!/bin/bash
SCRIPT_NAME="ClashXS"
SCRIPT_VERSION="20220617"
SCRIPT_MODE=""

WORK_DIR=~/.${SCRIPT_NAME}

CORE_VERSION=v1.11.2
CORE_DOWNLOAD_URL=""
CORE_BINARY=""
CORE_CONFIG=""
CORE_PATCH=""

YQ_VERSION=v4.25.2
YQ_DOWNLOAD_URL=""
YQ_BINARY=""

SUBSCRIBE_STORE=""
SUBSCRIBE_URL=""
SUBSCRIBE_FILE=""

err() {
  printf "Error: %s.\n" "$1" 1>&2
  exit 1
}

# 下载文件到本地
download() {
  [ -f $2 ] && return

  if [ -z "$3" ]; then
    curl -L $1 -o $2
  else
    curl -L $1 | $3 >$2
  fi
}

# 映射KV值
mapValue() {
  va=$(echo -n $2 | sed 's/|/\n/g' | grep "^$1\\s" | awk '{print $2}')
  echo -n ${va%%*( )}
}

prepareEnv() {
  # 获取系统类型和CPU架构
  OS=$(mapValue $(uname) 'Darwin darwin')
  ARCH=$(mapValue $(uname -m) 'amd64 amd64|arm64 arm64')

  ([ -z "$OS" ] || [ -z "$ARCH" ]) && err "unsupported operation system"

  # 创建工作目录
  [ ! -d "${WORK_DIR}" ] && mkdir "${WORK_DIR}"

  # 配置 yq
  YQ_BINARY="${WORK_DIR}/yq_${YQ_VERSION}"

  # 配置 core
  CORE_BINARY="${WORK_DIR}/core-${CORE_VERSION}"
  CORE_CONFIG="${WORK_DIR}/config.yaml"

  # 初始化订阅配置
  SUBSCRIBE_STORE="${WORK_DIR}/subscribe"
  SUBSCRIBE_FILE="${WORK_DIR}/origin.yaml"
  [ -f "${SUBSCRIBE_STORE}" ] && [ -z "$SUBSCRIBE_URL" ] && SUBSCRIBE_URL=$(cat $SUBSCRIBE_STORE)
}

# 下载依赖
prepareDeps() {
  download "${GH_MIRROR}https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}" "$YQ_BINARY"
  chmod +x "$YQ_BINARY"

  download "${GH_MIRROR}https://github.com/MetaCubeX/Clash.Meta/releases/download/${CORE_VERSION}/Clash.Meta-${OS}-${ARCH}-${CORE_VERSION}.gz" "$CORE_BINARY" 'gzip -d'
  chmod +x "$CORE_BINARY"
}

prepareSubscribe() {
  [ -z "$SUBSCRIBE_URL" ] && return

  # 删除过期订阅
  if [ -f "${SUBSCRIBE_FILE}" ]; then
    # 获取文件最后更新时间
    case $(uname) in
    Darwin)
      lastModify=$(stat -f %m ${SUBSCRIBE_FILE})
      ;;
    Linux)
      lastModify=$(stat -c %Y ${SUBSCRIBE_FILE})
      ;;
    esac
    # 计算时间差
    now=$(date +%s)
    [ $((now - lastModify)) -gt 10800 ] && rm -f $SUBSCRIBE_FILE
  fi

  [ ! -f "${SUBSCRIBE_FILE}" ] && download ${SUBSCRIBE_URL} ${SUBSCRIBE_FILE}
}

patchSubscribe() {
  [ ! -f "${SUBSCRIBE_FILE}" ] && echo 'subscribe file not exists.' && return

  $YQ_BINARY ea ". as \$item ireduce ({}; . * \$item ) ${CORE_PATCH}" ${SUBSCRIBE_FILE} - >${CORE_CONFIG} <<EOF
port: 7890
socks-port: 7891
allow-lan: false
log-level: warning
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 119.29.29.29
    - 223.5.5.5
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geosite:
      - gfw
    ipcidr:
      - 240.0.0.0/4
tun:
  enable: false
  stack: gvisor
  dns-hijack:
    - 8.8.8.8:53
    - tcp://8.8.8.8:53
  auto-route: true
  auto-detect-interface: true
EOF
}

launchCore() {
  stopCore
  [ ! -f "${CORE_CONFIG}" ] && return

  CORE_COMMAND="${CORE_BINARY} -d ${WORK_DIR}"

  # 检查是否启用 tun
  IS_TUN_ENABLED=$($YQ_BINARY e '.tun.enable' "${CORE_CONFIG}")

  [ "${IS_TUN_ENABLED}" == "true" ] &&
    # 以 root 用户运行 core
    CORE_COMMAND="sudo ${CORE_COMMAND}" &&
    # 申请 root 权限
    sudo $SHELL -c :

  # 启动服务
  nohup $SHELL >${WORK_DIR}/core.log 2>&1 <<EOF &
  echo -n $(basename ${CORE_BINARY}) >${WORK_DIR}/proc_name
  $CORE_COMMAND
  $SHELL $0 reset
EOF

  # 设置 DNS
  [ "${IS_TUN_ENABLED}" == "true" ] && sleep 3 && launchNameserver
}

stopCore() {
  [ ! -f "${WORK_DIR}/proc_name" ] && return

  # 检查是否启用 tun
  KILLER='killall'
  IS_TUN_ENABLED="true"

  ([ -f "$YQ_BINARY" ] && [ -f "$CORE_CONFIG" ]) && IS_TUN_ENABLED=$($YQ_BINARY e '.tun.enable' "${CORE_CONFIG}")
  [ "${IS_TUN_ENABLED}" == "true" ] && KILLER="sudo ${KILLER}"
  [ "${IS_TUN_ENABLED}" == "true" ] && stopNameserver

  $KILLER $(cat ${WORK_DIR}/proc_name) 2>/dev/null && rm -f ${WORK_DIR}/proc_name
}

launchNameserver() {
  OS=$(uname)
  if [ "$OS" == "Darwin" ]; then
    sudo $SHELL <<EOF
    networksetup -setdnsservers Wi-Fi 127.0.0.1 ;
    dscacheutil -flushcache ;
    killall -HUP mDNSResponder ;
EOF
  else
    err "unsupported operation system"
  fi
}

stopNameserver() {
  OS=$(uname)
  if [ "$OS" == "Darwin" ]; then
    sudo $SHELL <<EOF
    networksetup -setdnsservers Wi-Fi "Empty" ;
    dscacheutil -flushcache ;
    killall -HUP mDNSResponder ;
EOF
  else
    err "unsupported operation system"
  fi
}

displayHelp() {
  cat <<EOF
${SCRIPT_NAME} (${SCRIPT_VERSION}) - a shell based clash core manager

Usage: ClashXS.sh [options] [start|stop|reset]

Options:
  -s, --subscribe <Subscribe url>
  -d, --directory <Work directory>
  -m, --gh-mirror <Github mirror url>
  -v, --version   <Clash.Meta version>
  --http-port     <HTTP proxy port>
  --socks-port    <SOCKS proxy port>
  --lan
  -t, --tun
  -h, --help

Commands:
  start    Start the clash daemon
  stop     Kill/Stop the clash daemon
  reset    Reset system DNS settings
EOF
exit 0
}

while [ $# -gt 0 ]; do
  case $1 in
  start | stop | reset)
    SCRIPT_MODE=$1
    ;;
  -v | --version)
    CORE_VERSION=$2
    shift
    ;;
  -m | --gh-mirror)
    GH_MIRROR="$2"
    shift
    ;;
  -t | --tun)
    CORE_PATCH="${CORE_PATCH} | .tun.enable = true | .dns.listen = \"127.0.0.1:53\""
    ;;
  -d | --directory)
    WORK_DIR=$2
    shift
    ;;
  -s | --subscribe)
    SUBSCRIBE_URL=$2
    shift
    ;;
  --http-port)
    CORE_PATCH="${CORE_PATCH} | .port = $2"
    shift
    ;;
  --socks-port)
    CORE_PATCH="${CORE_PATCH} | .socks-port = $2"
    shift
    ;;
  --lan)
    CORE_PATCH="${CORE_PATCH} | .allow-lan = true"
    ;;
  -h | --help)
    displayHelp
    ;;
  esac
  shift
done

prepareEnv
case $SCRIPT_MODE in
start)
  prepareDeps
  prepareSubscribe
  patchSubscribe
  launchCore
  ;;
stop)
  prepareDeps
  stopCore
  ;;
reset)
  stopNameserver
  ;;
*)
  displayHelp
  ;;
esac
