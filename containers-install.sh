#!/bin/bash

# script will install, update or purge a range of docker containers
# check configuration initialisation array DOCKERS for configuration details of a container
#

# used Google to find standard docker container installation details.

# Open Source Initiative  https://opensource.org/licenses/RPL-1.5
#
#   Unless explicitly acquired and licensed from Licensor under another
#   license, the contents of this file are subject to the RECIPROCAL PUBLIC
#   LICENSE ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
#   and You may not copy or use this file in either source code or executable
#   form, except in compliance with the terms and conditions of the RPL.
#
#   All software distributed under the RPL is provided strictly on an "AS
#   IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, AND
#   LICENSOR HEREBY DISCLAIMS ALL SUCH WARRANTIES, INCLUDING WITHOUT
#   LIMITATION, ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
#   PURPOSE, QUIET ENJOYMENT, OR NON-INFRINGEMENT. See the RPL for specific
#   language governing rights and limitations under the RPL.
#
# Copyright (C) 2026, Teus Hagen, the Netherlands
#

VERSION=$(echo  '$Revision: 3.1 $ $Date: 2026/07/29 15:43:23 $' | awk '{ printf("V%s_%s", $2,$5);}')
SCRIPT=$0

# debug mode. Echo only the actions. Just for security
MSG=ALL                              # defaut message level: be very versatyle
if [ -n "${DEBUG}" ]                 # define 'DEBUG=echo' for only show actions
then
    MSG=DEBUG
    set -x
fi
_RUNNING=                            # has progressbar running ID

# Default list of containers is CONTAINERS
DEFAULTS="mosquitto zigbee2mqtt homeassistant wud go2rtc"
# home directory of containers. Directory where all docker conatiners reside and user homes
# DOCKERDIR=/opt                     # usual default for docker containers
DOCKERDIR=/home/containers           # docker containers homes directory
# backup directory. Suggest to use remote NAS or autofs to remote disk
BACKUP_DIR=${DOCKERDIR}/backups
# containers to be restored          used via the restore script option
declare -A RESTORE
# operational mode of operating e.g. purge or delete container(s), install or update container(s)
# will purge docker if no container images are found
MODE=UPDATE
VERBOSE=/dev/stderr                  # channel for messages. Default on /dev/stderr
# keep track of installed services and docker containers
declare -A INSTALLED
# docker interactions via sudo or via dockers group permission SUDO is empty
SUDO='sudo '  # default via sudo command
if groups | grep -q " docker "       # docker CLI command works for this USER
then
    SUDO=
fi
# installion logging file 
TMP_DIR=$(mktemp -d /var/tmp/DocInst_XXXXXXXXXX) # directory for temporary files

# collect error messages
function ERRORS() {
    local F=${1//*\//}
    if [ -z "$F" ] ; then return 0 ; fi
    if [ "$F" != errors ] && [ -s ${TMP_DIR}/"$F" ]
    then
        cat ${TMP_DIR}/"$F" >> ${TMP_DIR}/errors
        rm -f ${TMP_DIR}/"$F"
    fi
    return 0
}

# just to make messages and logging colorfull
# Bold
if [ -t 2 ]                        # print output channel is terminal (here stderr)
then
    Reg="\e[0;"            # Regular
    Bold="\e[1;"           # Bold
    Fained="\e[2;"         # Fained
    Italic="\e[3;"         # Italic
    Under="\e[4;"          # Underlined
    # background colors are 4N N=0-7, 9N is light color forground color
    # next are bold colors
    Black="\e[1;30m"       # Black
    Gray="\e[1;37m"        # Gray
    Red="\e[1;31m"         # Red
    Green="\e[1;32m"       # Green
    Yellow="\e[1;33m"      # Yellow
    Blue="\e[1;34m"        # Blue
    Purple="\e[1;35m"      # Purple
    Cyan="\e[1;36m"        # Cyan
    White="\e[1;97m"       # White
    # reset
    Reset="\e[0m"          # Text color reset
fi

# Define info function on exit
cleanup_success() {
  rm -rf ${TMP_DIR}              # clean up
}
cleanup_failure() {
  echo -e "${Red}Exiting on failure!${Reset}" >/dev/stderr
  for F in ${TMP_DIR}/*
  do
      if [ -z "${F/%*errors/}" ] && [ -s "${F}" ]
      then
          echo -e  "See for failures the error file $F." >/dev/stderr
      else
          rm -f "$F"
      fi
  done
  if [ -n "$_RUNNING" ] ; then kill $_RUNNING ; fi
}
cleanup() {
  if [ $? -eq 0 ]; then
    cleanup_success
  else
    cleanup_failure
  fi
}
trap cleanup EXIT
trap cleanup_failure INT

# info and logging handler, be verbose of what is going on
declare -A LEVEL                                  # information level for messages
LEVEL[EMERGE]=7
LEVEL[ALERT]=6
LEVEL[CRITICAL]=5
LEVEL[ERROR]=4
LEVEL[WARN]=3
LEVEL[NOTICE]=2
LEVEL[INFO]=1                                     # default
LEVEL[DEBUG]=0
LEVEL[ALL]=0
LEVEL[QUIET]=4                                    # errors and higher level
function MESSAGE () {
    local STR=${2:-$1} L=$1
    if [ -z "$2" ] ; then L=ALL ; fi
    case ${LEVEL[${L^^}]:-None} in                # set color level and message
        6|7) L=${Bold}${Purple}${L^^}${Reset} ; STR="${Purple}${STR}${Reset}"
        ;;
        5) L=${Bold}${Red}${L^^}${Reset} ; STR="${Red}${STR}${Reset}"
        ;;
        4) L=${Red}${L^^}${Reset} ; STR="${Red}${STR}${Reset}"
        ;;
        3) L=${Purple}${L^^}${Reset}
        ;;
        2) L=${Blue}${L^^}${Reset}
        ;;
        1) L=${Black}${L^^}${Reset}
        ;;
        0) L=${Gray}${L^^}${Reset}
        ;;
        *) return 1                               # do not show message
        ;;
    esac
    # show message when level is higher as quiet level
    if (( ${LEVEL[${1^^}]:-1} >= ${LEVEL[$MSG]:-4} ))   # level of publishing / versability level
    then
       echo -e "${L}: $STR" >>${VERBOSE}
    fi
    # stop if level is equal or higher as critical level
    if (( ${LEVEL[$1]:-1} >= ${LEVEL[CRITICAL]:-5} ))   # level of critical messages
    then
       echo "${Red}EXITING${Reset}." >>${VERBOSE}
       exit 1
    fi
}

# ***********************************************************************
# ******* docker images and container CONFIGURATION definitions *********
# ***********************************************************************
# docker container configuration: docker image, name and directory
# Home Assistant configuration
# starts as deamon with default arguments restart:always, name, TimeZone, docker socket

# default volume options timezone and docker.sock
DEFAULT_OPTIONS="
    --volume=/etc/localtime:/etc/localtime:ro
    --volume=/var/run/docker.sock:/var/run/docker.sock"
# container installation definitions should be in a sort of library database
declare -A DOCKERS                 # array with container installation details

HOSTIP=                            # server ip address for container webUI access
function HOSTIP() {
   if [ -n "$HOSTIP" ] ; then echo "$HOSTIP" ; return 0 ; fi
   HOSTIP=$(ifconfig | awk '/inet 1[09]/{ print $2; }' | sort -r | head -1)
   if ! echo "${HOSTIP:-localhost}" | grep -q -P '([0-9]{1,3}\.){3}[0-9]{1,3}'
   then
       echo localhost ; HOSTIP=localhost
       return 1
   fi
   return 0
}
HOSTIP

# show progress bar when notice level below N
function STOPbar() {                  # stop progress bar
    if [ -n "$_RUNNING" ]
    then
        kill $_RUNNING
        echo -e "\r${1} DONE     " >>$VERBOSE
    fi
    _RUNNING=
}
# show progress if run from terminal
# optional arg 1: max time in sec setting
function _PROGRESSBAR() {
   declare -a SYMB
   SYMB=( '.' '..' '...' '....' '.....')
   # Display progress bar
   for ((i=0; i < ${1:-180}; i++)); do # max 3 minutes
     if [ -t 2 ]
     then
         printf "\r %-5s %3ds" ${SYMB[$(($i%5))]} $(($i/2)) >>$VERBOSE
     fi
     sleep 0.50
   done
}
# arg 1: max time setting in sec
# do not show when level is high
function STARTbar() {                 # start the progress bar
   if ! [ -t 2 ] ; then return 0 ; fi
   if (( ${LEVEL[$MSG]:-3} >= ${LEVEL[QUIET]} )) ; then return 0 ; fi
   if [ -n "$_RUNNING" ] ; then kill $_RUNNIMG ; fi
    _PROGRESSBAR ${1:-180} &
    _RUNNING=$!
}
#STARTbar # default 180 seconds
#sleep 5
#STOPbar

# ***************** MQTT service ****************************************
# MOSQUITTO AUTH "$USER:passwd_string", if empty: anonymous
MQTT_HOST=${HOSTIP:-localhost}      # default host for MQTT service

MQTT_PORT=1883                      # default service port 1883
MQTT_USER=mosquitto                 # default MQTT service system owner: user:password
MQTT_CLIENT=                        # allowed user client: dflt: anonymous, or user[:password]
# installation configurations for docker containers
# configuration options: use ! char to indicate spaces. Will be converted to spaces.

# ************************** HOMEASSTANT *******************************
# see also: https://www.homeautomationguy.io/blog/home-assistant-tips/installing-docker-home-assistant-and-portainer-on-ubuntu-linux
# container HOMEASSISTANT WEBgui on port 8123
# service description
DOCKERS[homeassistant]="Home Assistant Systsem (HAS). WebGui on port 8123"
# docker container data (home) directory base
DOCKERS[homeassistant,HOME]=${DOCKERDIR}/homeassistant
# container image in repository docker
DOCKERS[homeassistant,IMAGE]=ghcr.io/home-assistant/home-assistant:stable
# container name
DOCKERS[homeassistant,NAME]=homeassistant         # should be unique or first 12 chars image ID
# docker run default options
DOCKERS[homeassistant,DFLT]=${DEFAULT_OPTIONS}
# run with user id with private data
DOCKERS[homeassistant,USER]=homeassistant
# run with WebGUI on port
DOCKERS[homeassistant,PORT]='--publish=8123:8123'   # WEBgui via http://localhost:8123
# install volumes in home dir of the container
DOCKERS[homeassistant,DATA]=/config
# containers needs more own arguments, maybe empty
# dbus is needed for BlueTooth access
DOCKERS[homeassistant,OPTIONS]="
    --volume=/run/dbus:/run/dbus:ro
    --volume=/run/dbus:/run/dbus:ro
    --device-cgroup-rule='c!188:*!rw'"            # !-char will be converted to spece
#    --workdir=/config
#    --privileged
#    --network=host
DOCKERS[homeassistant,ENV]="
    --env=TZ=Europe/Amsterdam
"
DOCKERS[homeassistant,CMD]=
DOCKERS[homeassistant,DPTS]=mosquitto             # HAS needs mosquitto or mqtt5
DOCKERS[homeassistant,PREP]="Preparation: Default homeassistant runs as user '${DOCKERS[homeassistant,USER]}'.
"
DOCKERS[homeassistant,AFTER]="
The docker container homeassistant will automatically start.
Login via http://$(HOSTIP):8123  to allow HAS to start search for devices and install integrations.
"
# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# ************************* ZIGBEE@MQTT *********************************
# ZIGBEE2MQTT docs: https://zigbee2mqtt.io/guide/installation and /configuration
# used: https://www.zigbee2mqtt.io/guide/installation/02_docker.html#running-the-container
# container ZIGBEE2MQTT (handle zigbee devices WEBgui on port 8080)
DOCKERS[zigbee2mqtt]="Zigbee to MQTT gateway service. WebGui on port 8080."
# docker container data (home) directory base
DOCKERS[zigbee2mqtt,HOME]=${DOCKERDIR}/zigbee2mqtt
DOCKERS[zigbee2mqtt,IMAGE]=ghcr.io/koenkk/zigbee2mqtt
DOCKERS[zigbee2mqtt,NAME]=zigbee2mqtt
DOCKERS[zigbee2mqtt,USER]=zigbee2mqtt           # runs as zigbee2mqtt user
DOCKERS[zigbee2mqtt,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[zigbee2mqtt,PORT]='--publish=8080:8080' # WEBgui via http://localhost:8080
# see: https://zigbee2mqtt.io/guide/adapters/ e.g. /ember2net.html
ZIGBEE_DONGLES="(Nabu_Casa|HubZ_Smart|Sonoff_Zigbee)" # defined dongles add more
# device will be detected automatically, group access is added to container
DOCKERS[zigbee2mqtt,DEVICE]=      # /dev/serial/by-id/usb-ZIGBEE-DONGLE-serial-if00
DOCKERS[zigbee2mqtt,DATA]=/app/data:rw          # where configuration.yaml resides
# CHANGE NEXT -- device  LINE !!!!!
# zigbee dongle: the device needs to be found via ls -l /dev/serial/by-id/ command!!!
DOCKERS[zigbee2mqtt,OPTIONS]="
   --volume=/run/udev:/run/udev:ro"
DOCKERS[zigbee2mqtt,ENV]="
    --env=TZ=Europe/Amsterdam
"
# zig2mqtt configuration.yaml to be updated with zigbee dongle, frontend, etc.
# container will startup hopefully without initial 'onboarding webGUI'.

# Some help to identify dongle:
#   lsusb: Shenzhen Riite (Sonoff with extra HAS firmware installed (/dev/ttyUSB0)
#  --device=
#   /dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_<your serial>-if00-port0:/dev/ttyACM0)"
# config serial:
#   port: /dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_<your serial>-if00-port0
#   adapter: ember
#   baudrate: 115200
#   rtscts: false

#   lsusb: Nabu Casa ZBT-2 (/dev/ttyACM0): 
#  --device=
#   /dev/serial/by-id/usb-Silicon_Labs_HubZ_Smart_Home_Controller-(your serial #)-if01-port0:/dev/ttyACM0
#   /dev/serial/by-id/usb-Nabu_Casa_ZBT-2_(your serial #)-if00:/dev/ttyACM0)
# see: https://community.home-assistant.io/t/zigbee2mqtt-zbt-2/955316/2
# config serial:
#   port: /dev/serial/by-id/usb-Nabu_Casa_ZBT-2_(your serial #)-if00
#   adapter: ember
#   baudrate: 460800
#   rtscts: true

# for accessERRORS resolution with ownership inside container, add e.g.
# --user=1001:1001 and gid dialout: --add-group=20
# docker run -it --entrypoint /bin/sh --device /dev/ttyACM0 koenkk/zigbee2mqtt -c "ls -halt /dev/ttyACM0"
# and/or run without detach and restart option
# add dialout:20:1 to /etc/subgid
# HUGE mention has to go to schklom: https://github.com/moby/moby/issues/43019#issuecomment-1062199525
# see also: https://stackoverflow.com/questions/76683335/passing-a-device-to-a-container-running-on-rootless-docker

# if needed command arguments
DOCKERS[zigbee2mqtt,CMD]=
DOCKERS[zigbee2mqtt,DPTS]=mosquitto     # container depends on service mosquitto to run
DOCKERS[zigbee2mqtt,PREP]="Preparation: Default zigbee2mqtt runs as user '${DOCKERS[zigbee2mqtt,USER]}'.
Make sure you identify where the Zigbee dongle is available. E.g. ls /dev/serial/by-id/ or change that in the configuration.
"
DOCKERS[zigbee2mqtt,AFTER]="
The docker container zigbee2mqtt will automatically start.
Use http://$(HOSTIP):8080 to define dongle Z2M configuration, log level and web frontend first.
If connected to dongle, the antenna led will stop flashing.
Then reload via http://$(HOSTIP):8080  to allow zigbee devices to join.
See: https://www.zigbee2mqtt.io/guide/configuration/

Serial dongle Z2M configuration:
  use 'ls /dev/serial/by-id/' to obtain device path and name
  port: e.g. /dev/serial/by-id/usb-Nabu_Casa_ZBT-2_(your serial #)-if00
  adapter: ember
  baudrate: 460800 for Nabu Casa, 115200 for Sonoff zigbee dongle
  rtscts: true for Nabu Casa, false for Sonoff dongle
"


# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# ************************* WUD *****************************************
# container WUD (containers automatic update service. WEBgui on 3000 port.)
DOCKERS[wud]="Watch's Update Docker service. WebGui on port 3000."
# docker container data (home) directory base
DOCKERS[wud,HOME]=${DOCKERDIR}/wud
DOCKERS[wud,IMAGE]=getwud/wud
DOCKERS[wud,NAME]=wud
DOCKERS[wud,USER]=
DOCKERS[wud,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[wud,PORT]='--publish=3000:3000'          # WEB gui as e.g. http://localhost:3000
DOCKERS[wud,DATA]=/store
# remove WUD_TRIGGER_DOCKER_LOCAL_PRUNE line for only get notices
# read WUD documenation for triggers for needs of other trigger actions as eg email
# do not use spaces in LOCAL_CRON env definition
# WUD CRON: check for updates weekly
# notify via email. Add next lines without comment char to OPTIONS list (not yet tested)
#    --env=WUD_TRIGGER_SMTP_LOCAL_HOST=smtp_server
#    --env=WUD_TRIGGER_SMTP_LOCAL_PORT=465  
#    --env=WUD_TRIGGER_SMTP_LOCAL_FROM_ADDRESS=this_host_address
#    --env=WUD_TRIGGER_SMTP_LOCAL_TO=recipient_email_address
# next 3 not required. For GMAIL one need to have a dedicated account for this
#    --env=WUD_TRIGGER_SMTP_LOCAL_USER=unknown
#    --env=WUD_TRIGGER_SMTP_LOCAL_PASS=abacadabra
#    --env=WUD_WATCHER_LOCAL_CRON=@weekly
#    !-char will be converted to space
DOCKERS[wud,ENV]="
    --env=TZ=Europe/Amsterdam
    --env=WUD_WATCHER_LOCAL_CRON='15!1!*!*!6'
    --env=WUD_TRIGGER_DOCKER_LOCAL_PRUNE=true"
DOCKERS[wud,CMD]=
DOCKERS[wud,PREP]="Preparation: Default wud runs as user '${DOCKERS[wud,USER]:-anonymous}'.
"
DOCKERS[wud,AFTER]="
A less simpler and more powerfull alternative is to install Portainer.
The docker container wud (What's up Docker) will automatically start.
Login via http://$(HOSTIP):3000.
See: https://getwud.github.io/wud/#/
"
# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# ************************ GO2RTC ****************************************
# container GO2RTC (container video streaming service WEBgui on port 1984)
# See: https://github.com/AlexxIT/go2rtc
DOCKERS[go2rtc]="Video streaming service. WebGui on port 1984."
# docker container data (home) directory base
DOCKERS[go2rtc,HOME]=${DOCKERDIR}/go2rtc
DOCKERS[go2rtc,IMAGE]=alexxit/go2rtc
DOCKERS[go2rtc,NAME]=go2rtc
DOCKERS[go2rtc,USER]=go2rtc                      # security?
DOCKERS[go2rtc,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[go2rtc,PORT]='--publish=1984:1984'       # WEB gui via http://localhost:1284
DOCKERS[go2rtc,DATA]=/config
DOCKERS[go2rtc,OPTIONS]=""
#    --privileged
#    --network=host"
DOCKERS[go2rtc,ENV]="
    --env=TZ=Europe/Amsterdam
"
DOCKERS[go2rtc,CMD]=
DOCKERS[go2rtc,PREP]="Preparation: Default go2rtc runs as user '${DOCKERS[go2rtc,USER]:-anonymous}'.
"
DOCKERS[go2rtc,AFTER]="
The docker container go2rtc (the ultimate camera stream application) will automatically start.
See: https://docs.frigate.video/guides/configuring_go2rtc/
Or github pages: https://github.com/AlexxIT/go2rtc
"
# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# *********************** MATTER ****************************************
# From: https://github.com/matter-js/python-matter-server/blob/main/docs/docker.md
# container MATTER (containers update server)
DOCKERS[matter]="Generalized device managing service for matter devices. Preferrable via Thread."
# docker container data (home) directory base
DOCKERS[matter,HOME]=${DOCKERDIR}/matter
#DOCKERS[matter,IMAGE]=ghcr.io/home-assistant-libs/python-matter-server:stable
DOCKERS[matter,IMAGE]=ghcr.io/matter-js/python-matter-server:stable
DOCKERS[matter,NAME]=matter
DOCKERS[matter,USER]=                           # security?
DOCKERS[matter,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[matter,PORT]=
DOCKERS[matter,DATA]=/data
DOCKERS[matter,OPTIONS]="
    --network=host
    --security-opt=apparmor=unconfined"
DOCKERS[matter,ENV]="
    --env=TZ=Europe/Amsterdam
"
# WITH BLUETOOTH LOCAL COMMISIONING add cmd args after image:
#      --storage-path /data --paa-root-cert-dir /data/credentials --bluetooth-adapter 0
DOCKERS[matter,CMD]=
DOCKERS[matter,DPTS]=homeassistant
DOCKERS[matter,PREP]="Preparation: Default matter runs as user '${DOCKERS[matter,USER]:-anonymous}'.
"
DOCKERS[matter,AFTER]="
The docker container matter will automatically start and integrates with HAS.
See: https://www.home-assistant.io/integrations/matter/
"
# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# *********************** MQTT ****************************************
# this is not operational!!!
# thanks to: https://github.com/sukesh-ak/setup-mosquitto-with-docker
# container MQTT (containers update server) Alternative to mosquitto service
DOCKERS[mqtt5]="Mosquitto service (eclipse) for MQTT messages e.g. zigbee2mqtt, tasmota, etc. WebGui on port ${MQTT_PORT:-1883}. Not operational."
# docker container data (home) directory base
DOCKERS[mqtt5,HOME]=${DOCKERDIR}/mqtt5
DOCKERS[mqtt5,IMAGE]=eclipse-mosquitto
DOCKERS[mqtt5,NAME]=mqtt5
DOCKERS[mqtt5,USER]=mosquitto
DOCKERS[mqtt5,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[mqtt5,PORT]="--publish=${MQTT_PORT:-1883}:1883"
DOCKERS[mqtt5,PORT]+=" --publish=9001:9001"
DOCKERS[mqtt5,DATA]="
    /data
    /config
    ${DOCKERS[mqtt5,HOME]}/log"
DOCKERS[mqtt5,OPTIONS]="
    --network=host"
DOCKERS[mqtt5,CMD]=
DOCKERS[mqtt5,PREP]="Preparation: Default mqtt5 runs as user '${DOCKERS[mqtt5,USER]:-anonymous}'.
"
DOCKERS[mqtt5,AFTER]="
The docker container mqtt5 (MQTT service) will automatically start and integrates with HAS.
See: https://www.hivemq.com/blog/how-to-get-started-with-mqtt/
"
# default args: --name, --restart, --env TZ, --user, --publish, --volume /var/run/docker.sock

# ************************* LyrionMusicServer ***************************
# container lyrionmusic server : plays music from central archive to lyrion players (RPi4+)
DOCKERS[lyrionmusic]="LyrionMusic Server for Lyrion Players. WebGui on port 9000."
# docker container data (home) directory base
DOCKERS[lyrionmusic,HOME]=${DOCKERDIR}/lyrionmusic
DOCKERS[lyrionmusic,IMAGE]='lmscommunity/lyrionmusicserver:stable'
DOCKERS[lyrionmusic,NAME]=lyrionmusic
DOCKERS[lyrionmusic,USER]=lyrionmusic
DOCKERS[lyrionmusic,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[lyrionmusic,PORT]="--publish=3483:3483/tcp"
DOCKERS[lyrionmusic,PORT]+=" --publish=3483:3483/udp"
DOCKERS[lyrionmusic,PORT]+=" --publish=9000:9000/tcp"
DOCKERS[lyrionmusic,PORT]+=" --publish=9090:9090/tcp"
DOCKERS[lyrionmusic,DATA]=/conf
DOCKERS[lyrionmusic,OPTIONS]="
           --env=HTTP_PORT=9000 \
           --device=/dev/snd:/dev/snd:rwm
           --workdir=/config"
DOCKERS[lyrionmusic,ENV]="
    --env=TZ=Europe/Amsterdam
"
DOCKERS[lyrionmusic,CMD]=
DOCKERS[lyrionmusic,PREP]="Preparation: Default lyrionmusic runs as user '${DOCKERS[lyrionmusic,USER]:-anonymous}'.
"
DOCKERS[lyrionmusic,AFTER]="
The docker container lyrionmusic LMS (Lyrion Music Server) will automatically start and integrates with HAS.
Login via http://$(HOSTIP):9000
The server needs one or more LMS clients to listen to the music. E.g. via RPi running simple special image.
See: https://lyrion.org/
"

# ************************* Portainer ***************************
# see: https://pimylifeup.com/raspberry-pi-portainer/
# container portainer server : docker container GUI manager (create, edit, stop) on port 9443
DOCKERS[portainer]="Portainer docker container (create/edit/stop/start) manager. WubGui on port 9002."
# docker container data (home) directory base
DOCKERS[portainer,HOME]=${DOCKERDIR}/portainer
DOCKERS[portainer,IMAGE]='portainer/portainer-ce:latest'
DOCKERS[portainer,NAME]=portainer
DOCKERS[portainer,USER]=
DOCKERS[portainer,DFLT]=${DEFAULT_OPTIONS}
DOCKERS[portainer,PORT]="--publish=8000:8000/tcp"
# https access:
#DOCKERS[portainer,PORT]+=" --publish=9443:9443/tcp"
# may need this for http access
DOCKERS[portainer,PORT]+=" --publish=9002:9000/tcp"
DOCKERS[portainer,OPTIONS]="
           --env=HTTP_PORT=9000"
DOCKERS[portainer,DATA]=/data
DOCKERS[portainer,ENV]="
    --env=TZ=Europe/Amsterdam
"
DOCKERS[portainer,CMD]=
DOCKERS[portainer,PREP]="Preparation: Default portainer runs as user '${DOCKERS[portainer,USER]:-anonymous}'.
"
DOCKERS[portainer,AFTER]="
The alternative is to install WUD (What's up Docker).
The docker container Portainer (docker containers manager) on port 9443 will automatically start.
To administer the first user login inmidiately via http://hostname:9002 or via https://hostname:9443.
If not in time just restart portainer to put portainer in authorisation modus.

See: https://pimylifeup.com/raspberry-pi-portainer/
or https://cylab.be/blog/434/simplify-your-docker-management-with-portainer
or for integration to homeassistant:
https://www.homeautomationguy.io/blog/home-assistant-tips/installing-docker-home-assistant-and-portainer-on-ubuntu-linux
"

# ***************************** END CONTAINER RUN DEFS ******************

# ################# services configurations #############################
# ***************** DOCKER **********************************************
# either via open source apt, or via docker.com ???
# DOCKER container service apps
DOCKERdotCOM=YES         # to disable make this empty
# or use:
DOCKER_APPS="docker-buildx-plugin docker-rootless-extras docker.io"
# DOCKER EXTRA packages
# python only needed if python docker API is used, not yet needed
# compose if compose is used, not yet needed
#DOCKER_ADDON="docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose python3-docker"
# how to get more inside of running docker containers:
# hint: see docker documentation for usefull commands as 'ps', 'ls', 'cp', 'exec', 'logs', etc.
DOCKER_ADDON=python3-docker
# use python script inspect.py to check docker run args with running containers

declare -A SERVICES
SERVICES[docker]="Docker container install and management system service/deamon."
SERVICES[mosquitto]="Mosquitto system broker service for MQTT messages e.g. from zigbee2mqtt, tasmota, etc."
MQTT_CONF=/etc/mosquitto/conf.d/HAS.conf

# ***************************** END SERVICES CONFIG DEFS ****************

# ***********************************************************************
# **************************** script functions *************************
# definition of functions used in this bash script

# check if service on port arg1 is accessable (arg2: also from remote)
# arg1: port, optional arg2: host (dflt HOSTIP local IP number)
function LISTENING() {                 # port is accessable?
    local H=${2:-${HOSTIP}}
    MESSAGE INFO "Check port $1 can be accessed from remote IP ${H}. This can take a while."
    if netcat -w 10 -z $H ${1:-12345} 2>/dev/null
    then
        return 0
    else
        sleep 15                            # wait to allow process to start up
        if netcat -w 10 -z $H ${1:-12345} 2>/dev/null
	then
	   return 0
	fi
    fi
    return 2
}

# function to obtain docker cmd 'run' from existing container
# updated alternative for older docker_replay python script
# TO DO: use existing containers installation details and allow run with updated arguments
function DOCKER_rerun(){
    MESSAGE WARN "Docker rerun script is not yet implemented."
    return 1
} 

# correct directory ownership
# arg1: directory to create, arg2: ownership
function SET_DIRECTORY() {
    if ! ${SUDO:-sudo} mkdir -p "$1" || ! ${SUDO:-sudo} chmod 755 "$1"
    then
        return 1
    fi
    if [ -n "$2" ] && ! ${SUDO:-sudo} chown -R "${2}:${2}" "$1" ; then return 1; fi
    return $?
}

# check if docker container image needs own home directory and is known as user.
# this is optional. Arg: containter name. Attention: dialout handling for user as uid:dialout.
# arg1: user id, arg2: container name
function CREATE_USER(){
    local USERID=${1/:*/} GRP CNTR=$2
    if ! [ "${1/*:/}" = dialout ]
    then
        if [ -n "${1/*:/}" ] && ! grep -q "^${1/*:/}:" /etc/group
        then
            ${SUDO:-sudo} addgroup ${1/*:/}
        fi
        GRP="--ingroup ${1/*://}"
    fi
    if [ -n "${USERID}" ]
    then
        if ! grep -q "^${USERID}:" /etc/passwd 
        then
             if [ -z "${CNTR}" ]
             then
                  MESSAGE WARN "Missing container name for new user '${1/:/ group }'."
                  return 1
             fi
             # add user with gid to system accounts, disabled login
             # add user will set subuid and set subgid in container name space
	     ${SUDO:-sudo} mkdir -p "${DOCKERS[$CNTR,HOME]}"
             if ! ${SUDO:-sudo} adduser \
                          --disabled-password --disabled-login \
                          --stdoutmsglevel=warn \
                          --comment "Docker container ${CNTR} user" \
                          --no-create-home \
                          ${GRP} \
                          --stdoutmsglevel=err --logmsglevel info \
                          --home "${DOCKERS[$CNTR,HOME]}" \
                          "${USERID}"
	     then
	          MESSAGE ERROR "Unable to create user '${1/:/, group }'.\nSkip container '${CNTR}' installation."
	          return 1
	     fi
             if ! SET_DIRECTORY "${DOCKERS[$CNTR,HOME]}" "${USERID}"
             then
                  MESSAGE ERROR "Failed to set dir ownership ${DOCKERS[$CNTR,HOME]}."
                  return 1
             fi
             MESSAGE NOTICE "Installed user ${1/:/, group member of }.\nHome directory '${DOCKERS[$CNTR,HOME]}' for container '${CNTR}'."
        fi
        if [ "${DOCKERS[${CNTR},USER]/*:/}" = dialout ]
        then
            ${SUDO:-sudo} usermod -aG dialout "${DOCKERS[${CNTR},USER]/:*/}"
        fi
    fi
    return $?
}

# generate compose.yaml file for 'docker compose up -d container-name' from CLI docker run file
# args: container-name CLI-run-args-file output-yaml-file-name
# run args has lines as --option-name=item and is sorted
function COMPOSERIZE() {
    local CNTR="$1" IN="${2:-/dev/null}" OUT="${3:-/dev/stderr}"
    if ! [ -s "$IN" ] ; then return 1 ; fi
    if ! [ -w $OUT ]
    then
         MESSAGE CRITICAL "Unable to write to YAML file $OUT."
         return 1
    fi
    MESSAGE ERROR "Not yet supported."
    MESSAGE NOTICE "Use https://www.composerize.com/ conversion service."
    return 1
    MESSAGE NOTICE "Create compose YAML file $OUT for docker container compose $CNTR."
    if [ -s $OUT ]
    then
        MESSAGE WARN "YAML file exists! Will append to the file"
    else
        echo  "services:" >$OUT   # do not overwrite
    fi
    date +"  # Docker compose YAML for $CNTR Created on %d-%m-%Y %H:%M." >>$OUT
    echo  "  $CNTR:" >>$OUT
    # TO DO awk -v T=NONE
    return 0
}

# generate docker run container arguments (alternative is to use compose YML)
# generate docker run CLI optineal arguments. 
# use composerize function to convert options to compose.yaml file
# arg1 containername, optional arg2: generate options but do not add UID etc. 
function CMD_RUN_CNTR() {
    # ARG1=name container,
    # if present e.g. ARG2=INFO it's called from HELP (no system changes)
    local CNTR=$1 TYPE ID INFO=''
    INFO+="\nOptional webGUI access of container '$CNTR':"
    INFO+="\n    ${DOCKERS[$CNTR]}"
    local RTS=0 ITEM D
    # compile run argument list
    for TYPE in LABEL NAME DFLT USER OPTIONS ENV DATA PORT DEVICE # sorted list of docker run options
    do
        # if [ -z "${DOCKERS[$CNTR,$TYPE]}" ] ; then continue ; fi
        if echo "${DOCKERS[$CNTR,$TYPE]}" | grep -q UNDEFINED
        then
             MESSAGE ERROR "Container '$CNTR' with type '$TYPE' needs UNDEFINED completed. Skipped."
             MESSAGE NOTICE "See: $(echo "${DOCKERS[$CNTR,$TYPE]}" | grep UNDEFINED)"
             RTS=1
        fi

        case "$TYPE" in
	LABEL)
	    INFO+="\nAdded labels to container: script $VERSION, creation date."
	    echo "--label=localhost.script=${SCRIPT}_${VERSION}"
	    echo "--label=localhost.created=$(date +%Y/%m/%d-%H:%M)"
	;;
        DFLT)
            INFO+="\nDefault run arguments: ${DOCKERS[$CNTR,DFLT]}."
            for ITEM in ${DOCKERS[$CNTR,DFLT]}
            do
                echo "${ITEM//!/ }"
            done
        ;;
        DATA)
            for ITEM in ${DOCKERS[$CNTR,DATA]}
            do
		ITEM=${ITEM//!/ }
                D=${ITEM/:*/} ; D=${DOCKERS[${CNTR},HOME]}${D/\/*\//\/}
                echo "--volume=${D}:${ITEM}"
            done
        ;;
        DEVICE)
	    if [ -z "${DOCKERS[$CNTR,DEVICE]}" ]
	    then
		    DOCKERS[$CNTR,DEVICE]=$(GET_DONGLE $CNTR)
	    fi
            for ITEM in ${DOCKERS[$CNTR,DEVICE]}    # should be something like --device=/dev/tty:/dev/USB0
            do
	       ID=${ITEM/*=/}                       # get serial device of the dongle
	       # next depends if script USER has permission for /dev/serial/by-id directory
	       # this may require sudo
	       ID=$(readlink -f "${ID/:*/}")        # get GUID of dongle for access rights
	       # add to group which has access
               if ! [ -c "${ID}" ]
               then
                   INFO+="\nDevice ${ID} is not a character device!. Not added as device."
	       else
		   INFO+="\nAdding device ${ITEM/*=/} for container."
                   echo "${ITEM}"                   # to do: add mapping to eg /dev/ttyUSB0
	           ID=$(ls -g $ID | awk '{ print $3;}') 
	           INFO+="\nAdding group ${ID} for access to device."
	           echo "--group-add=${ID}"
	       fi
	       if [  -z "$2" ]       ]              # add group kernel mapping
	       then
		   if ! grep -q ${ID} /etc/subgid
		   then                      # this may need a system reboot to enable it
		       ID="${ID}:$(grep ${ID} /etc/group | cut -d: -f3):1"
		       (cat /etc/subgid; echo "${ID}") >${TMP_DIR}/subgid
		       ${SUDO:-sudo} cp ${TMP_DIR}/subgid /etc/subgid
		       rm -f ${TMP_DIR}/subgid
		   fi
               fi
	       ID=
            done
        ;;
        PORT)
            for ITEM in ${DOCKERS[$CNTR,PORT]}
            do
                echo "${ITEM}"
            done
        ;;
        OPTIONS)
            INFO+="\n Added extra options: ${DOCKERS[$CNTR,OPTIONS]}"
            for ITEM in ${DOCKERS[$CNTR,OPTIONS]}
            do
                echo "${ITEM//!/ }"
            done
        ;;
        ENV)
            for ITEM in ${DOCKERS[$CNTR,ENV]}
            do
                if echo "$ITEM" | grep -q UNDEF
                then
                    INFO+="\nYou need to configure $ITEM!"
                else
                    echo "${ITEM//!/ }"
                fi
            done
        ;;
        NAME)
            # default name: first 12 chars of image id
            if [ -n "${DOCKERS[$CNTR,NAME]}" ]
            then
                 echo "--name=${DOCKERS[$CNTR,NAME]:-UNDEFINED}"
            fi
            INFO+="\nContainer name: '${DOCKERS[$CNTR,NAME]:-first 12 chars of image id}'"
        ;;
        USER)
            ID=${DOCKERS[$CNTR,USER]}  # do not create account. COMPOSE is run from HELP
            local U=${ID/:*/} G=${ID/*:/}
            if [ "$G" = dialout ]
            then                       # just for compatability previous version
                G=$(awk -F : '/^dialout:/{ printf("%d\n", $3);}' /etc/group)
                if !  grep -q 'dialout:' /etc/subgid
                then
		     if [ -z "$2" ]
		     then
                         ${SUDO:-sudo} sh -c "echo dialout:$G:1 >>/etc/subgid"
                         INFO+="\nAdded 'dialout' to gid namespace map /etc/subgid."
	             else
                         INFO+="\nWill add 'dialout' to gid namespace map /etc/subgid."
	             fi
                fi
            elif [ -n "$U" ] && grep -q "^$U:" /etc/passwd
            then
                G=$(id -g $U)
            fi
            if [ -n "${U}" ]
            then
                if [ -n "$2" ]        # called from HELP
                then
                    echo "--user=UID_of_${ID/:*/}:GID_of_${ID/*:/}"
                else
                    echo "--user=$(id -u ${U}):${G}"
                fi
                INFO+="\nRuns as user ${U} under group ${ID/*:/}."
            else
                INFO+="\nRuns with ${Purple}'anonymous'${Reset} permissions!"
            fi
        ;;
        *)
            MESSAGE ERROR "Run args container '$CNTR' encountered unknown type '${Red}${TYPE}${Reset}'!"
            echo "${DOCKERS[$CNTR,$TYPE]}"
        ;;
        esac
    # next is a trick to get only one line if ran with /dev/null argument
    done | sort | uniq | sed '/^ *$/d'  >$TMP_DIR/args
    if [ -n "${DOCKERS[$CNTR,IMAGE]}" ]
    then
        INFO+="\nDocker container image:\t'${DOCKERS[$CNTR,IMAGE]}'"
        echo "${DOCKERS[$CNTR,IMAGE]}" >>$TMP_DIR/args
    else
        MESSAGE ALERT "Configuration error. Missing container '$CNTR' image pull identifier."
        exit 1
    fi
    if [ -n "${DOCKERS[$CNTR,CMD]}" ]
    then
          INFO+="\nCommand and cmd arguments: ${DOCKERS[$CNTR,CMD]}."
          for _ in ${DOCKERS[$CNTR,CMD]}
          do
              echo "$_" >>$TMP_DIR/args
          done
    fi
    INFO+="\nSee ${DOCKERS[$CNTR,HOME]}/data/log/datum.time for logging info."
    MESSAGE INFO "${INFO}"
    # TMP_DIR/args has CLI 'docker run --detach' arguments
    awk '/^ *$/{ next ;} { print; }' $TMP_DIR/args # delete empty lines
    rm -f $TMP_DIR/args
    return $RTS
}

# ##################################################################
# ################ HELP ############################################
# #################################################################
# help dump, restore container backups
function BACKUP_HELP() {
    echo -e "
To dump container data use: '$CMD dump container_name ...'.
To restore container data use: '$CMD restore container_name ...'.
Docker local container data will be stored in an unencrypted (!) compress datafile in the directory $BACKUP_DIR in the subdirectory container_name.
Dump files exceeding 3 tar-files and older as one month and will be removed.
Suggested is to store e.g. via autofs and SMB-archive on a remote (NAS) filesystem.
In this way the dumps arrive automatically on a remote (NAS) filesystem.
Install autofs: 'sudo apt install autofs ; sudo systemsctl enable autofs'.
Add file: 'echo \"${BACKUP_DIR} -fstype=cifs,rw,username=USER,password=USER_SECRET_PHRASE,dir_mode=0777,file_mode=0777 ://NAS_HOST/has_system\" | sudo tee /etc/auto.smb.shares'.
Append smb share: 'echo \"/- /etc/auto.smb.shares --timeout 15 browse\" | sudo tee -a /etc/auto.master'
and 'sudo systemctl restart autofs'.
Add on NAS system in file /etc/samba/smb.conf:
'
# autofs on /dev/smbXYZ
[has_system]
    path = /extra/HAS
    comment = containers homeassistant and zigbee2mqtt backup data
    read only = no
    browseable = no
    force create mode = 0660
    force directory mode = 2770
    valid users = @USER
    '
and restart smbd on the NAS.
Remember homeassistant has encrypted (tar) backups in home subdirectory 'backups'. Make sure to save the encryption key.
Optionally homeassistant will create unencrypted dumps.
Homeassistant new install will allow to restore the archived data on startup in the initial WebGui page.
"

}

# help information on stdout
function HELP(){
    local CNTRS=$(echo ${!DOCKERS[@]} | sed 's/,[A-Z][A-Z]*//g' | \
                awk '{ for(i=1;i<=NF;i++){print $i};}' | sort | uniq )
    local CNTR
    if [ -z "$1" ]
    then
        echo -e "
$SCRIPT script version: $VERSION

How to use this command:
   ${Black}$0 [--level=LEVEL|--debug|help|default|install|purge|container|service ...]${Reset}

Optional argument:
'--level=LEVEL' or '-l=LEVEL': level of verbosity, default level: $MSG
    Levels of verbosity (prioritized): $(echo ${!LEVEL[@]} | sed 's/ /, /g').
'--debug': Script will show statements executed. Or use CLI environment variable DEBUG=on.
    In debug mode the script will install containers with tty and attached.
    Tip: Terminal access to running container: 'docker debug container_name'.
'${Black}help${Reset}' gives this information as shown here.
'${Black}help${Reset} name1 ...' shows container docker 'docker run --detach ...'

'${Black}install${Reset}' installs or updates a docker container/image or system service (docker, mosquitto).
'${Black}update${Reset}' update and restarts a docker container.
    Install or update may be followed with container name(s). Default: default set of containers.
'container' is either a container name (prefer lowercase) or defaults (all default containers).
The container will be created via the 'docker run args ... image' (detached/always start),
    where args are generated by the script.
    A copy can be found in container home directory: 'setup.sh'.
    Use enivironment variable DEBUG to run The script 'setup.sh' in attach mode. 
    On successful install an experimental compose.yaml file is generated in the container home directory.
'service' either mosquitto or docker will do a system service installation.

Command arguments configuration examples:
${Blue}$CMD defaults${Reset}
     Runs with default container/image and service set.
     Default containers or services are: ${DEFAULTS// /, }.

${Blue}$0${Reset} ${Red}delete${Reset} ${Blue}[container|service ...]${Reset}
${Blue}$0${Reset} ${Red}purge${Reset} ${Blue}[container|service ...]${Reset}
     Will stop, remove, delete container(s) and image(s).
     'purge' will not remove local stored data in home directory. 'delete' removes local data.
     If container name is 'docker' the docker app also will be removed from system.

${Blue}$0 help${Reset} ${Black}container_name${Reset}
     Will show actions and help when installing '${Black}name${Reset}'.
     Before installing containers or services first use 'help service/container'.

${Black}dump container_name ...${Reset} Create a 'tar' dump of container data directory.
     Store the data in ${BACKUP_DIR} directory for each installed container.
     Amount of dumps is limited to 3. First in, first removed.
     Default: make a dump of all installed container data.
     If setup.sh is available or 'help container' from script is ok,
     one can rm with docker CLI the container and use docker run or compose to start container.
     Hint: save the dumps on a separate filesystem! To do: encrypt the archive.

${Black}restore container_name ...${Reset} Restore a container from tar dump archive.
     Search and interact on available archived or user provided dump/config file
     for the docker container with container_name.
     Will pull latest image, unroll dump, and restart container.
     If setup-sh in archived dump is available use the the setup script. Setup script
     will prefer to start the container via compose.yaml file.

Some operations need super user 'root' permission (using --privileged as option).
If super user password is needed the script will ask via 'sudo' for the 'root' password. Once the pasword is entered the script will reuse the provide root permission via 'sudo'.

The script will install automatically dependent system service(s) or containers when needed so.
If a docker image is already installed and running,
the script will try to  update the image and restart the container or service.
Note that if the docker container ${Black}WUD${Reset} is installed,
one does not need to run this script for image version updates.

${Black}Advise${Reset}:
Before installing a docker container one is advised to obtain some preparation information.
E.g. use the command '${Black}$CMD help ${Blue}container_name${Reset}'.

An alternative is to use Portainer docker container to create,
add/delete configuration items to the container, stop and restart, update docker containers.
And use '${Black}help container_name${Reset}' to give hints for the container configuration items. 
Portainer is however more complex to manage.

The script will use preconfigured installation. See DOCKER array variable definitions to change them if needed.
Docker container may use a serial dongle device. The group needed to access it is automatically discovered and added as group membership for the container. E.g. dialout. A reboot maybe required to activate user and group id mapping in hte OS kernel.

${Black}TO DO${Reset}:
- identify and use an available and running MQTT service on local network.
- if container is already installed use the container configuration.
- the docker container run argumentes could be converted to compose a yaml file.
"
        if (( ${#SERVICES[@]} > 0 ))
        then
            echo -e "\n${Black}Available and configured debian installable services${Reset}:"
            for CNTR in ${!SERVICES[@]}
            do
               printf "  ${Blue}%-16s${Reset}: %s\n" "${CNTR}" "${SERVICES[$CNTR]}."
            done
            echo -e "Manage the debian service via CLI command (remote ssh):\n  ${Black}sudo systemctl${Reset} [start|restart|stop|status|enable] ${Black}ServiceName${Reset}."
        fi
        if echo "$CNTRS" | grep -q '[a-z][a-z]'
        then
            echo -e "\n${Black}Available and configured docker containers${Reset}:"
            for CNTR in ${CNTRS}
            do
               printf "  ${Blue}%-16s${Reset}: %s\n" "${CNTR}" "${DOCKERS[$CNTR]}."
            done
            echo -e "Manage docker containers via CLI command:\n  '${Black}docker${Reset} [ps|restart|stop|status] ${Black}dockerContainerName${Reset}'.\nOr use (remote) 'portainer' or 'wud'."
        fi
    fi
    if [ -z "$1" ] ; then exit 0 ; fi
    
    local Y=yes                # show installation information for a container
    if (( ${LEVEL[$MSG]} >= ${LEVEL[QUIET]} ))
    then
         Y=                    # do not show installation detailed info
    fi
    for CNTR in $@
    do
        if [ -z "${CNTR/#-*/}" ]
        then
            echo "Option $CNTR is an option? Skipped."
            continue
        fi
        if [ "${CNTR,,}" = defaults ]
        then
             HELP $DEFAULTS
             continue
        fi 
	if echo " backup dump restore " | grep -q "${CNTR}"
        then
	     BACKUP_HELP
	     continue
	fi
	#  HELP container_name
        if echo $CNTRS | grep -q "${CNTR}"
        then
            if systemctl --quiet is-active docker
            then
                # is container running?
                if ${SUDO}docker ps --format '{{.Names}}' | grep -q "${CNTR}"
                then
                    [ -z "$Y" ] || echo -e "Docker container ${CNTR} is ${Black}already installed and running${Reset}."
                elif ${SUDO}docker inspect "${DOCKERS[${1},IMAGE]:-None}" >/dev/null >/dev/null
                then
                    [ -z "$Y" ] || echo -e "Docker container ${CNTR} ${Black}image is installed${Reset} and ${Red}inactive${Reset}."
                fi
            else
                [ -z "$Y" ] || echo -e "${Black}Docker is not running or not installed${Reset}. The script also install 'docker'."
            fi

            if [ -n "${DOCKERS[${CNTR},PREP]}" ]
            then
                 echo -e "${Black}Before installation some notes${Reset}:\n${DOCKERS[${CNTR},PREP]}"
            fi
            echo -e "How the docker container '${Black}${CNTR}${Reset}' is installed and activated via run command:"
            echo -e "    Install image: '${Black}docker pull ${DOCKERS[${CNTR},IMAGE]}${Reset}' followed by"
            if [ -n "${DOCKERS[${CNTR},USER]}" ] && ! grep -q "^${DOCKERS[${CNTR},USER]:-root}:" /etc/passwd
            then
                 [ -z "$Y" ] || echo -e "Container user ${Black}${DOCKERS[${CNTR},USER]:-anonymous} as owner${Reset} will be installed (user login is disabled)."
            else
                 echo -e "Container runs as user/group ${DOCKERS[${CNTR},USER]:-anonymous}: '${Black}docker run${Reset} ${Blue}arguments${Reset}' (see CLI command)."
            fi
            echo -e -n "${Black}"
            CONFIG_CHECK ${CNTR:-None} INFO
	    echo -e "Command to run the container ${CNTR}:"
	    # maybe use composerize to convert run option to yaml file
	    if (( ${LEVEL[$MSG]} <= ${LEVEL[INFO]} ))
	    then
	      CMD_RUN_CNTR ${CNTR} help | \
                    awk '/--[a-z]/{ sub("=","\t");}
		         { printf("    %s \\\n", $0);}
			 END { print "\n";}'
	    fi
            [ -z "$Y" ] || echo -e "${Reset}"
            if [ -n "${DOCKERS[$CNTR,AFTER]}" ]
            then
                 echo -n -e "${Black}After installation${Reset}:"
                 echo "${DOCKERS[$CNTR,AFTER]}"
            fi
            echo -e "Manage docker containers via CLI command:\n  '${Black}docker${Reset} [ps|restart|stop|status] ${Black}$CNTR${Reset}.\nOr use (remote) 'portainer' or 'wud'."
        elif echo "${!SERVICES[@]}" | grep -q "${CNTR}"
        then
            systemctl --quiet is-active ${CNTR}       # check already installed/running
            case $? in
            4)
            echo -e "${Black}${CNTR}${Reset} is not installed or active.\nWill install it as debian system service."
            ;;
            1|2|3)
            echo -e "${Cyan}${CNTR}${Reset} is installed and ${Red}not active${Reset}."
            ;;
            0)
            echo -e "${Blue}${CNTR}${Reset} is installed and active."
            ;;
            esac
            echo -e "Manage the debian service via CLI command (remote ssh):\n  ${Black}sudo systemctl${Reset} [start|restart|stop|status|enable] ${Black}$CNTR${Reset}."
        else
            echo -e "Name '${Red}$CNTR${Reset}' as docker container name is not defined in DOCKERS list."
        fi
    done
    exit 0
}

# installs docker. Command maybe redone as 'docker' group id is added to $USER
# from https://github.com/sukesh-ak/setup-mosquitto-with-docker/blob/main/install-docker.sh
# ref: https://docs.docker.com/engine/install/debian/#install-using-the-repository
# docker service is not installed to be remotely accessable for security reasons.
function INSTALL_DOCKER(){
    MESSAGE INFO "Update OS system libraries, etc. first. System upgrade is not done."
    STARTbar
    ${SUDO:-sudo} apt-get update -qq
    STOPbar "System updating"
    
    if [ -n "$DOCKERdotCOM" ] # install using docker.com Linux install script
    then
        MESSAGE NOTICE "Install docker from get.docker.com. Can take a while..."
        # disadvantage: docker will not be updated automatically
	STARTbar
        curl -sSL https://get.docker.com >${TMP_DIR}/install
        if [ -n "${DEBUG}" ]
        then
            MESSAGE DEBUG "Dry run docker installation:"
            ${SUDO:-sudo} bash ${TMP_DIR}/install --dry-run
        else
            if ! ${SUDO:-sudo} bash ${TMP_DIR}/install 2>&1 >$TMP_DIR/msg
            then
                 ERRORS msg    # save errors messages
                 MESSAGE ALERT "Docker installation failed.\nSee logging ${TMP_DIR}."
		 STOPbar "Failure installing docker."
                 exit 1
            fi
        fi
	STOPbar "Installed docker core."
        rm -f ${TMP_DIR}/{msg,install}
    else
        MESSAGE NOTICE "Installation of docker container service apps: ${DOCKER_APPS}."
        STARTbar
        if ! ${SUDO:-sudo} apt install ${DOCKER_APPS} -y -q 2>&1 >${TMP_DIR}/apps
        then
             STOPbar "Install ${Red}${DOCKER_APPS}"
             ERRORS apps
             MESSAGE ALERT "Docker installation 'apt install ${DOCKER_APPS}' failed!"
             exit 1
        fi
        STOPbar "Install ${Blue}${DOCKER_APPS}${Reset}"
        rm -f ${TMP_DIR}/apps
    fi
    
    # Create hello world container to test :) 
    MESSAGE DEBUG "Check: if docker runs ok:"
    if ! ${SUDO}docker run hello-world 2>&1 | grep -q  'Hello from Docker'
    then
        MESSAGE EMERGE "Docker service failed to install."
        exit 1
    fi

    # install docker add on applications and/or libraries
    if [ -n "${DOCKER_ADDON}" ]
    then
        MESSAGE INFO "Docker add on's installation: ${DOCKER_ADDON// /, }."
        STARTbar
        ${SUDO:-sudo} apt-get update -qq
        ${SUDO:-sudo} apt-get install ${DOCKER_ADDON} -y -qq
        STOPbar "Installing docker add on's"
    fi

    if ! [ -d "${DOCKERDIR}" ]      # check if docker containers directory exists
    then
        MESSAGE NOTICE "Created directory '${DOCKERDIR}' where docker data reside."
        ${SUDO:-sudo} mkdir -p "${DOCKERDIR}"  # if not create the directory
    fi
    if ! grep -q '^docker:' /etc/group
    then
        ${SUDO:-sudo} groupadd docker 
    fi
    if ! grep -q "^docker:.*$USER" /etc/group
    then
        MESSAGE NOTICE "To avoid 'sudo' user '$USER' is added to the group 'docker'."
        ${SUDO:-sudo} usermod -aG docker $USER
        MESSAGE NOTICE "Group membership 'docker' is only activated after next login."
    else
        SUDO=
    fi
}

# install mosquitto service
function INSTALL_MOSQUITTO() {
    if LISTENING ${MQTT_PORT:-1883} REMOTE
    then
         MESSAGE WARN "There is already an MQTT service running on port ${MQTT_PORT:-1883}. Skipping installation."
         return 1
    fi 
    MESSAGE NOTICE "Installing mosquitto service, mosquitto add on's, local config and passwd file."
    STARTbar
    ${SUDO:-sudo} apt-get update -qq    # update system libraries first
    if ! ${SUDO:-sudo} apt-get install mosquitto -y -qq 2>&1 >>${TMP_DIR}/mosquitto
    then
        STOPbar "Install ${Red}mosquitto${Reset}"
        MESSAGE ERROR "Failed to install system service $SRVR."
        ERRORS mosquitto
    fi
    STOPbar "Install ${Blue}mosquitto${Reset}."
    rm -f ${TMP_DIR}/mosquitto

    if ! which /usr/bin/mosquitto_sub >/dev/null 2>/dev/null
    then
        MESSAGE INFO "Install $SRVR clients for MQTT debugging."
        STARTbar
        if ! ${SUDO:-sudo} apt install ${SRVR}-clients -y -qq 2>&1 >>${TMP_DIR}/mosquitto
        then
            STOPbar "Install ${Red}${SRVR}-clients${Reset}"
            MESSAGE WARN "Failed to install '${RSVR}-clients'."
            ERRORS mosquitto
        fi
        STOPbar "Install ${Blue}${SRVR}-clients${Reset}"
    fi
    rm -f ${TMP_DIR}/mosquitto

    ${SUDO:-sudo} systemctl --quiet enable mosquitto 2>/dev/null

    # authentication of subscribers and publishing clients
    if [ -n "${MQTT_USER/:*/}" ]
    then
        MESSAGE NOTICE "Change user/pwd mosquitto with 'man mosquitto_passwd' (/etc/mosquitto/pwdfile)"
        local NEW=
        if [ -f /etc/mosquitto/pwdfile ] ; then NEW=-c ; fi
        ${SUDO:-sudo} mosquitto_passwd -b ${NEW} /etc/mosquitto/pwdfile "${MQTT_USER/:*/}" "${MQTT_USER/*:/}"
    else
        MESSAGE NOTICE "For security:\n    add USER to mosquitto: sudo mosquitto_passwd -c /etc/mosquitto/pwfile USER"
    fi
    local ANONIMOUS=true
    if echo "${MQTT_CLIENT}" | grep -q ':' && [ -z "${MQTT_CLIENT/*:/}" ] # false if password is defined?
    then 
        if read -p "Run MQTT with client permissions anonimous? Yes|no: " -t 30 ANONIMOUS
        then
            if [ -z "${ANONIMOUS/[Yy]*/}" ]
            then ANONIMOUS=true
            else ANONIMOUS=false
            fi
        fi
    fi
    # Another mosquitto service is running? E.g. multiple zigbee2mqtt services.
    # One may need to add bridge modus in the config file.
    # Or mqtt filter service in the config file!
    MESSAGE INFO "MQTT client access anonimous is '$ANONIMOUS'."
    MESSAGE NOTICE "Configuring MQTT file for HAS: ${MQTT_CONF}."
    ${SUDU:-sudo} touch ${MQTT_CONF}
    echo "# needed for home assistant, disable/enable allow_anonimous
${MQTT_USER/[a-zA-Z]*/user ${MQTT_USER/:*/}}
#persistence_file mosquitto.db
#persistence_location
#log_dest stderr
#log_type error
#log_type warning
#log_type notice
#log_type information
#acl_file
#restart_timeout 5 30
#try_private true
pid_file /run/mosquitto/mosquitto.pid
listener ${MQTT_PORT:-1883}
#persistence true
#persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log
allow_anonymous $ANONIMOUS
" | ${SUDO:-sudo} sed -e "w ${MQTT_CONF}" -e d
    ${SUDO:-sudo} sed -i -e 's/^persistence/# persistence/' -e 's/^user/# user/' -e 's/^log_dest/# log_dest/' /etc/mosquitto/mosquitto.conf
    
    if ! ${SUDO:-sudo} systemctl --quiet restart mosquitto >/dev/null
    then
         MESSAGE ALERT "Failed to restart mosquitto service.\nCheck journal and logging: e.g. run 'mosquitto -v -c /etc/mosquitto/mosquiito.conf'"
         return 1
    fi
    return 0
}

# ##########################################################
# ############## ADD SERVICE deamon ########################
# ##########################################################
# add debian standard service (these are not docker containers)
function ADD_SERVICE(){
    local SRVR=${1} STATUS
    systemctl --quiet is-active ${SRVR}  # check if service deamon is running
    STATUS=$?
    case ${STATUS} in
    0)
          MESSAGE DEBUG "System service '${SRVR}' is already installed and running."
          return 0
    ;;
    1|3)  MESSAGE CRITICAL "Service $SRVR deamon is not running. Restart deamon."
    ;;
    2)    MESSAGE CRITICAL "Service $SRVR deamon needs to be started."
    ;;
    *)    MESSAGE INFO "Installing and starting $SRVR deamon."
    ;;
    esac

    STATUS=1
    case $SRVR in
    docker)
        INSTALL_DOCKER
        STATUS=$?
    ;;
    mosquitto)
        INSTALL_MOSQUITTO
        STATUS=$?
    ;;
    esac
    if (( $STATUS = 0 ))
    then
        INSTALLED[${SRVR}]="${Green}Installed system service $SRVR${Reset}."
	if [ ${SRVR} = mosquitto ]
	then
	    INSTALLED[${SRVR}]+=" Port $MQTT_PORT."
	fi
    else
        MESSAGE ERROR "Unknown system service '$SRVR'. Skipped."
	INSTALLED[${SRVR}]="${Red}Failed to install container $SRVR${Reset}."
    fi
    return 1
}
 
# import (pull) Home Assistant docker container image. Arg: container name.
function GET_IMAGE(){
    local IMG=0
    declare -i CNT=0
    if ${SUDO}docker images | grep -q "${1}"
    then                                 # some image is already imported
        IMG=1
    fi
    MESSAGE DEBUG "Check and get latest container '${1}' image '${DOCKERS[${1},IMAGE]}'.\nThis takes some while..."
    # some container repros fail first time, but are succefull second trial. E.g. go2rtc pull image.
    # check if there is an update.
    # Return 0 on success, return 1 if image is already existant.
    # Return 2 if image was up to date. Return 4 on failure. Return 3 on image inspect error.
    for (( CNT=0; CNT < 2; CNT++ ))
    do
        STARTbar
        if ! ${SUDO}docker pull "${DOCKERS[${1},IMAGE]}" >${TMP_DIR}/pull
        then                  # some repros e.g. go2rtc have caching problems. Try again.
            STOPbar "${Red}Pull image ${DOCKERS[${1},IMAGE]}${Reset}"
	    MESSAGE WARN "Failed to pull (try $CNT) image ${DOCKERS[${1},IMAGE]}. Try again."
	    sleep 15
            ERRORS pull
	    rm -f ${TMP_DIR}/pull
	else
	    STOPbar "${Green}Pulled image ${DOCKERS[${1},IMAGE]}${Reset}"
            break
	fi
    done
    if ! [ -f ${TMP_DIR}/pull ]
    then
        MESSAGE WARN "Failed to pull image ${DOCKERS[${1},IMAGE]}. Unknown image?"
        return 4
    fi
    if grep -q 'up to date' ${TMP_DIR}/pull
    then
        rm -f ${TMP_DIR}/pull
        if ${SUDO}docker ps --format '{{.Names}}' | grep -q '${1}'  # is container running?
        then
            return 2        # still running fine
        fi
    else
        rm -f ${TMP_DIR}/pull
    fi
    # check if image is uploaded and installed as image
    if ! ${SUDO}docker inspect "${DOCKERS[${1},IMAGE]}" >/dev/null >/dev/null
    then
        MESSAGE WARN "Failed to install docker image '$1'. Archive problem?"
        return 3
    fi
    return $IMG
}

# ######################################################################
# ################### GET a BACKUP of a container ######################
# ######################################################################
# create a backup of data store and setup instructions for container s
# local data backup directory. optional: args container ...
function GET_BACKUP(){
    local BDIR CNTR
    declare -i RTS=0
    if [ -z "$1" ]      # backing up all installed containers
    then
	BDIR=$(echo ${!DOCKERS[@]} | sed 's/,[A-Z][A-Z]*//g' | \
                awk '{ for(i=1;i<=NF;i++){print $i};}' | sort | uniq )
        for CNTR in $BDIR
	do
	    if [ -d "${DOCKERS[$CNTR,HOME]}" ]      # installed container dir
	    then
		GET_BACKUP $CNTR
		RTS+=$?
            else
		continue
	    fi
	done
	return $RTS
    fi
    #  may need to encrypt backup data
    for CNTR in $@
    do
        BDIR=$(${SUDO:-sudo} ls ${DOCKERS[${CNTR},HOME]:-not_available} 2>/dev/null)
        if ! [ -n "$BDIR" ]
        then
             MESSAGE WARN "Nothing to backup for container ${CNTR}. Or not existant."
             continue
        else
             BDIR=$BDIR
        fi
	declare -i CNT=0
        if [ ! -d "${BACKUP_DIR}/${CNTR}" ]
        then
            ${SUDO:-sudo} mkdir -p "${BACKUP_DIR}/${CNTR}"
	else
	    CNT=$(${SUDO:-sudo} find "${BACKUP_DIR}/${CNTR}" -maxdepth 1 -name 'Backup*.tgz' | wc -l) 
            if (( ${CNT:-0} > 3 ))
	    then                          # retain some, remove oldest, but retain 3 files
	        CNT-=3
	        CNT=$(${SUDO:-sudo} find "${BACKUP_DIR}/${CNTR}" -maxdepth -name 'Backup*.tgz' -print '%T+ %p\n' | sort | cut -f 2 -d ' ' | head -n $CNT )
		MESSAGE INFO "Removing backups ($CNT) of docker container '${CNTR}'."
		rm -f ${CNT}
	    fi
        fi
        MESSAGE INFO "Available backups for '${CNTR}', data: ${BDIR// /, }."
        local FBACKUP="${BACKUP_DIR}/${CNTR}/Backup-$(date +%Y-%m-%dH%H).tgz"
        MESSAGE NOTICE "Pause and backing up container data ${CNTR} HOME to '${Blue}$FBACKUP${Reset}'."
	# ${SUDO}docker ${CNTR} stop ; ${SUDO}docker ${CNTR} wait
	${SUDO}docker ${CNTR} pause   # better to stop and missing events? 
        ${SUDO:-sudo} tar --directory=${DOCKERS[${CNTR},HOME]} -czf "$FBACKUP" .
	RTS+=$?
	# ${SUDO}docker ${CNTR} start
	${SUDO}docker ${CNTR} unpause
    done
    return $RTS
}

# stop running container. ARG: container name
function STOP_CONTAINER(){
    local ONE
    for ONE in $@
    do
        if ${SUDO}docker ps --format "{{.Names}}" | grep -q "${ONE}"
        then
            MESSAGE INFO "Stopping container '$ONE' ..."
            if ! ${SUDO}docker stop "${ONE}" >/dev/null
            then
                MESSAGE WARN "Unable to stop container '${ONE}'."
                continue
            fi
        fi
    done
    return 0  # the container $1 is not running anymore
}

# #######################################################################
# ################ DELETE CONTAINER ############## cleanup ##############
# #######################################################################
# delete home and user credentials of a container from the system
function DELETE_CONTAINER(){
    local CNTR=${1:-None}
    if [ -n "${DOCKERS[$CNTR,USER]/:*/}" ] && grep -q "${DOCKERS[$CNTR,USER]/:*/}:" /etc/passwd
    then
        MESSAGE NOTICE "Remove user:group ${DOCKERS[$CNTR,USER]} home and local data from system."
        ${SUDO:-sudo} deluser --quiet --logmsglevel info --remove-home ${DOCKERS[$CNTR,USER]/:*/}
    fi
    if [ -d "${DOCKERS[${CNTR},HOME]}" ]
    then
        MESSAGE NOTICE "Cleanup and remove ${DOCKERS[${CNTR},HOME]} from the system."
        ${SUDO:-sudo} rm -rf ${DOCKERS[${CNTR},HOME]}
    fi
}

# stop and remove installed running container and image. ARG: name or image name/ID
function REMOVE_IMAGE(){
    local ONE IMAGE
    for ONE in $@
    do
        if ${SUDO}docker inspect "$ONE" --format "{{.Name}}" 2>/dev/null >/dev/null
        then
            STOP_CONTAINER "$ONE"                      # stop running container
            ${SUDO}docker rm "$ONE"          # remove the docker container
        fi
        IMAGE=$(docker image ls --all --format table 2>/dev/null | awk -v CNT=0  "/${ONE:-UNKOWN}/{ if( CNT++ == 0) { print \$3; }} END { if( CNT > 1) { exit(CNT); }}") 
        if (( $? > 1 )) && [ -n "$IMAGE" ]
        then
            MESSAGE WARN "Found more as one image with name like '$ONE.\nUsing only $IMAGE id."
        fi
        if [ -n "$IMAGE" ]
        then
            MESSAGE INFO "Removing docker container name '${ONE}' with image '${IMAGE}' from docker configuration."
            if ! ${SUDO}docker rmi ${IMAGE}  # remove image
            then
                MESSAGE WARN "Unable to remove container image for '${ONE}'."
            fi
        else
            MESSAGE WARN "Unable to find image for of docker container $CNTR."
        fi
        continue
    done
    return 0
}

# ****************** here all docker problems just start **************************
# zigbee2mqtt MQTT service URL and credits configuration
# zigbee2mqtt configuration via environment settings iso via configuration.yaml
# see for more: https://www.zigbee2mqtt.io/guide/configuration/mqtt.html
function ZIGBEE2MQTT_MQTT(){
    local ITEM
    for ITEM in $@
    do
        case "$ITEM" in
          server)
            if ! LISTENING ${MQTT_PORT:-1883} ${MQTT_HOST:-localhost}
            then
	        MESSAGE NOTICE "No running MQTT service (mosquitto?), detected.\nService is needed for zigbee2mqtt or configure a remote one."
                return 1
	    fi
	    echo "  server: mqtt://${MQTT_HOST:-localhost}:${MQTT_PORT:-1883}"
            MESSAGE INFO "Using MQTT service: mqtt://${MQTT_HOST:-localhost}:${MQTT_PORT:-1883}."
          ;;
          user)
            if [ -n "${MQTT_CLIENT/:*/}" ]
            then
                echo "  user: ${MQTT_CLIENT/:*/} "
                MESSAGE INFO "Zigbee2mqtt MQTT user ${MQTT_CLIENT/:*/}."
            else
	        echo "  # user: anonimous"
                MESSAGE WARN "Zigbee2mqtt MQTT  user anonymous."
	    fi
	    ;;
          password)
            if echo "${MQTT_CLIENT}" | grep -q ':' && [ -n "${MQTT_CLIENT/*:/}" ]
            then
               echo "  password: ${MQTT_CLIENT/:*/}"
               MESSAGE DEBUG "Zigbee2mqtt MQTT user password ${MQTT_CLIENT/*:/}."
	    else
	       echo "  # password: acacadabra"
               MESSAGE WARN "Zigbee2mqtt MQTT user/password: anonymous!"
            fi
            ;;
        esac
    done
    return 0
}

# add environment variable settings to env run CLI command
# depreciated
function ENV_ZIGBEE2MQTT_CONFIG() {
    local CONFIGS ITEM RTS=0
    CONFIGS+="AVAILABILITY_ENABLED=true"   # sets availability of a device
    CONFIGS+=$( ZIGBEE2MQTT_MQTT )         # sets MQTT access
    CONFIGS+=$( ZIGBEE2MQTT_DEVICE )       # sets Zigbee dongle device
    if [ -n "$DEBUG" ]                     # sets loglevel from info (default) to debug
    then
        CONFIGS+="ADVANCED_LOG_LEVEL=debug "
    fi
    for VAR in ${CONFIGS}
    do
       if [ -z "$ITEM" ] || ! [ -n "${ITEM/*_*=*/}" ] ; then continue ; fi
       DOCKERS[zigbee2mqtt,ENV]+="
            --env=ZIGBEE2MQTT_CONFIG_${ITEM}
"
   done
   return 0
}

# download current default zigbee2mqtt configuration yaml file
# arg1: output file e.g. /dev/stdout
# github: Koenkk/zigbee2mqtt
function ZIGBEE2MQTT_DFLT() {
    local CONF=${1:-/dev/stdout}
    local GITHUB=https://raw.githubusercontent.com/Koenkk/zigbee2mqtt/refs/heads/master/data/configuration.example.yaml
    echo -e "# downloaded $(date +%Y-%m-%d) default config file\n# from: $GITHUB" >>${CONF}
    if ! wget -q --output-document=- "${GITHUB}" >>${CONF}
    then
         MESSAGE WARN "Failed to download default yaml configure file.\nUsing own default."
         echo "version: 5" >>${CONF}
    fi
    return 0
}

# check if python3 lib ruamel.yaml exists
function YAML_LIB_INSTALLED() {
    if ! python3 -c '
try: from ruamel.yaml import YAML
except: raise Exception("No YAML library installed.")
'      </dev/null 2>/dev/null   
    then return 1
    else return 0
    fi
}

# merge yaml files via python3 script
# merge arg1, arg2 (dflt stdin) into arg3 (dflt stdout)
function YAML_MERGE() {
    if [ -z "$1" ] ; then return 1 ; fi 
    if ! YAML_LIB_INSTALLED
    then
         if ! ${SUDO:-sudo} apt install python3-ruamel.yaml -y 2>/dev/null >/dev/null
         then
             MESSAGE ERROR "Require ruamel.yaml python lib. Unable to intall it."
             return 1
	 else
             MESSAGE INFO "Needed ruamel.yaml python lib: intalled."
         fi
    fi
    python3 -c '
#!/usr/bin/python3
# merge yaml files: join_yaml.py fileIN1 fileIN2 ... fileOUT
try: from ruamel.yaml import YAML
except: raise Exception("No YAML library found. Install ruamel.yaml")
import sys
if len(sys.argv) < 4: raise Exception("need at 2+ input files and output file")

yaml = YAML()
try:
    for i in range(1,len(sys.argv)-1):              # combine files
        with open(sys.argv[i], "r", encoding = "utf-8") as yaml_file:
            if i < 2: data = yaml.load(yaml_file)   # original
            else: data.update(yaml.load(yaml_file)) # update
    with open(sys.argv[-1], "w") as yaml_output:    # write out yaml
        yaml.dump(data, yaml_output)
except: Exception("YAML merge failure.")
'   $1 ${2:-/dev/stdin} ${3:-/dev/stdout} 2>/dev/null
    return $?
}
    
# if configuration.yaml does not exists download dist default, merge with local conf items
# else just use old config file. TO DO: merge with update items.
# TO DO: ask to update exiting configuration.yaml file and update the file
# arg1: empty or called from CLI help argument: PRETTY PRINT formation
function ZIGBEE2MQTT_CONF() {
    local INF=${1}                                # only HELPINFO? PRT only
    local CONF=${DOCKERS[zigbee2mqtt,DATA]/:*/}
    local TYPE BRATE RTSCTS DBG=${DEBUG/?*/debug}
    CONF=${DOCKERS[zigbee2mqtt,HOME]}/${CONF/\/*\//}/configuration.yaml
    if ! [ -s ${CONF} ]
    then                                            # create a default config yaml file
        ZIGBEE2MQTT_DFLT ${TMP_DIR}/dflt-conf.yaml  # get default config file
	# define local configuration.yaml changes
        if echo "${DOCKERS[zigbee2mqtt,DEVICE]}" | grep -q -P "(Sonoff_Zigbee)"
        then
            BRATE=115200 ; RTSCTS=false             #elif NaBu dflt: BRATE=460800 RTSCTS=true
        fi
        echo -e "
# Local updates via container install d.d. $(date '+Y-%m-%d %H:%M')
frontend:
  enabled: true
  port: 8080
# Home Assistant integration (MQTT discovery)
homeassistant:
  enabled: false
# MQTT local settings
mqtt:
  base_topic: zigbee2mqtt
$(ZIGBEE2MQTT_MQTT server user password)
# Serial settings, only required when Zigbee2MQTT fails to start with:
#   USB adapter discovery error (No valid USB adapter found).
serial:
  port: /dev/ttyACM0
  adapter: ${TYPE:-ember}
  baudrate: ${BRATE:-460800}
  rtscts: ${RTSCTS:-true}
# Periodically check whether devices are online/offline
availability:
  enabled: true
# Advanced settings
advanced:
  log_level: ${DBG:-info}
  channel: 11
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
"        >${TMP_DIR}/local-conf.yaml
         # merge/update dflt and local to ${CONF}
	 YAML_MERGE ${TMP_DIR}/dflt-conf.yaml ${TMP_DIR}/local-conf.yaml ${TMP_DIR}/update-conf.yaml
	 if [ -n "$INF" ]
         then
	     echo -e "Zigbee2mqtt localized configuration.yaml file: ${CONF}" >${VERBOSE}
	     if (( ${LEVEL[$MSG]} < ${LEVEL[WARN]} ))
	     then
		     (echo "#----"; cat ${TMP_DIR}/update-conf.yaml; echo "#----") >${VERBOSE}
	     fi
	 else
             ${SUDO:-sudo} mv ${TMP_DIR}/update-conf.yaml ${CONF}
             if [ -n "${DOCKERS[zigbee2mqtt,USER]/:*/}" ]
             then
                 ${SUDO:-sudo} chown ${DOCKERS[zigbee2mqtt,USER]/:*/}:${DOCKERS[zigbee2mqtt,USER]/:*/} ${CONF}
             fi
             ${SUDO:-sudo} chmod 664 ${CONF}
             MESSAGE INFO "Created (updated) zigbee2mqtt configuration file: ${CONF}."
	 fi
         rm -f ${TMP_DIR}/{dflt,local,update}-conf.yaml
    else
         MESSAGE WARN "Using existing zigbee2mqtt yaml config file."
	 MESSAGE NOTICE "Change network_key and expan_id to GENERATE in configuration yaml file if needed so."
    fi
    if [ -n "$DEBUG" ]
    then
	(echo -e "Content ${CONF} yaml file:\n#----"; cat ${CONF}; echo "#----") >$VERBOSE
    fi
    return 0
}

# get device for a container. Try automatic detect for serial dongle
# arg1: container name, arg2: empty or HELP information only called from CLI help argument
function GET_DONGLE(){
     local DONGLE RTS=0 INF=$2
     case "${1}" in
         zigbee2mqtt)
             if ! [ -d /dev/serial/by-id/ ]
             then
                 DONGLE=/dev/serial/by-id/FAKE_ZIGBEE_DONGLE_SERIAL_NR
                 MESSAGE ${INF:-WARN} "${Red}No Zigbee dongle found${Reset}.\nUsing e.g. a fake one: ${Red}$DONGLE${Reset}?"
             else 
                 DONGLE=$(ls /dev/serial/by-id/ | grep -P "$ZIGBEE_DONGLES" | head -1)
                 DONGLE=/dev/serial/by-id/${DONGLE}
             fi
             if [ -z "${DOCKERS[$1,DEVICE]}" ] && [ -z "$DONGLE" ]
             then
                  DONGLE=/dev/ttyACM0
                  MESSAGE NOTICE "Zigbee2mqtt will use dongle '/dev/ttyACM0' as zigbee dongle."
	     elif [ -z "$DONGLE" ]
	     then
		  DONGLE=${DOCKERS[$1,DEVICE]/--device=/} ; DONGLE=${DONGLE/:*/}
             fi
             if ! [ -c "${DONGLE}" ]
             then
                 MESSAGE ${INF:-WARN} "Device ${DONGLE} does not exists! Using /dev/ttyACM0"
                 echo "--device=/dev/ttyACM0:/dev/ttyACM0"
                 RTS=1
             else
                 echo "--device=${DONGLE}:/dev/ttyACM0" # map real dongle to ACM0
             fi
         ;;
         *)
	     if [ -n "$2" ] && [ -c "$2" ]
	     then
                 echo "--device=${DOCKERS[$1,DEVICE]}:/dev/ttyUSB0"
	     fi
	 ;;
     esac
     return $RTS
}

# Container may have a prepaired and updated own configuration startup file
# arg1: container name, arg2: if defined only for HELP info
function CONFIG_CHECK(){
    case "$1" in
    zigbee2mqtt)
	# configure zigbee2mqtt configuration.yaml for operational container and webGUI
        ZIGBEE2MQTT_CONF $2
	return $?
    ;;
    esac
    return 0
}

# restore docker container
# get file with archived local container data from dump directory or user input
# arg1: container_name, ADD_CONAINER function will use this data
# collect into RESTORE[container_name]=archived_file
function GET_RESTORE_DATA() {
   local CNTR={1:-None} ANSWER
   declare -a FILE
   declare -i CNT=0
   if ! echo ${!DOCKERS[@]} | awk '{for(i=1;i <= NF;i++){sub(",[A-Z]*","",$i); print $i;}}' | sort -r | uniq | grep -q "^${CNTR}$"
   then
       MESSAGE ERROR "Unknown docker container $CNTR. Skipped."
       return 1
   fi

   if [ -d "${BACKUP_DIR}/${CNTR}" ]
   then                              # time sorted array of available archived data
       FILE=($(${SUDO:-sudo} find "${BACKUP_DIR}/${CNTR}" -maxdepth -name 'Backup*.tgz' -print '%T+ %p\n' | sort | cut -d ' ' -f 2))
   fi
   if (( ${#FILE[@]} > 0 ))
   then
       echo -e "Found in "${BACKUP_DIR}/${CNTR}" ${#FILE[@]} backups (youngest first):" >$VERBOSE
       for (( CNT=0; CNT < ${#FILE[@]} ; CNT++ ))
       do
           echo -e "${Red}$CNT${Reset}\t${FILE[$CNT]}" >$VERBOSE
       done
       read -p "Enter which number? ${#FILE[@]} or enter path/filename or leave it blank (none): " -t 30 ANSWER
   fi
   if [ -n "$ANSWER" ]
   then
       RESTORE[$CNTR]=${FILE[$ANSWER]}
   else
       read -p "Enter your backup file (compressed) tar file: " -t 30 ANSWER
       if [ -z "$ANSWER" ] ; then return 1 ; fi
       if ${SUDO:-sudo} file -z "${ANSWER:-NoNe}" | grep -q 'POSIX tar'
       then
           RESTORE[$CNTR]="$ANSWER"
           return 0
       fi
   fi
   MESSAGE WARN "Unable to locate archived tar dump file for contaner $CNTR."
   return 1
}

# restore archived or config data for a docker container
function RESTORE_DATA() {
    local CNTR=${1,,} FILE=${RESTORE[${CNTR}]}
    if [ -z "$FILE" ] ; then return 0 ; fi
    STOP_CONTAINER ${CNTR}
    Z=$(${SUDO:-sudo} file -z ${FILE})
    if ! echo "$Z" | grep -q "POSIX tar"  # wonder how this can be generalized
    then
	MESSAGE ERROR "Provided container archive file $FILE format not supported."
	return 1
    fi
    ${SUDO}docker rm ${CNTR}
    if ! ${SUDO:-sudo} tar --directory="${DOCKERS[${CNTR},HOME]}" ${DEBUG/*/-tv} -xf $FILE
    then
	MESSAGE WARN "Unable to retrieve archived file $FILE for container $CNTR. Restart container."
	${SUDO}docker restart $CNTR
	return 1
    fi
    MESSAGE WARN "Installed archived or config file $FILE for container ${CNTR}."
    return 0
}
                   
# ############################################################
# ##############   ADD CONTAINER container_name  #############
# ############################################################
# upload, install or update image and startup the container to run as deamon. ARG: name
function ADD_CONTAINER(){
    local CNTR="$1"
    declare -i STATUS=0
    case ${CNTR} in
    mqtt5)
        if pgrep mosquitto >/dev/null && LISTENING ${MQTT_PORT:-1883} 
        then
            MESSAGE WARN "MQTT 'mosquitto' service is already active on port ${MQTT_PORT:-1883}."
            return 1
        fi
    ;;
    esac
    # check if image is installed. If not install/pull it from repository 
    GET_IMAGE "${CNTR}"
    case $? in
     3|4)
         MESSAGE ERROR "Image for container '${CNTR}' cannot be installed. Skipped."
         return 1
     ;;
     2)
         MESSAGE INFO "Container image '${CNTR}' is now updated."
         # just restart container
         if systemctl --quiet is-active docker
         then
             if ${SUDO}docker ps --format '{{.Names}}' | grep -q "${CNTR}"
             then
                 MESSAGE INFO "Restart docker container ${CNTR}."
                 if ! ${SUDO}docker restart "${CNTR}"
		 then
		     MESSAGE ERROR "Failed to restart updated container ${CNTR}."
                     return $?
		 fi   
             fi
         fi
         ${SUDO}docker restart "${CNTR}"
         # TO DO: check if container config needs to be changed
     ;;
     1)
         MESSAGE INFO "Container image '${CNTR}' is up to date."
         # TO DO: check if container config needs to be changed
     ;;
     *)
         MESSAGE INFO "Installed container image '${CNTR}'."
     ;;
    esac

    # docker image has been imported, updated to latest, not running yet
    if ! ${SUDO}docker ps --format "{{.Names}}" | grep -q "${CNTR}"
    then                      # docker image is new or stopped, check user and group id's
        if [ -n "${DOCKERS[${CNTR},USER]}" ]
        then                  # check if system user exists
            CREATE_USER "${DOCKERS[${CNTR},USER]}" "${CNTR}"
        fi
        local ITEM GRP
        if [ -n "${DOCKERS[${CNTR},USER]/:*/}" ] # get device group owner dialout (20)
        then
             if [ "${DOCKERS[${CNTR},USER]/*:/}" = dialout ]
             then
                 GRP=":${DOCKERS[${CNTR},USER]/*:/}"
             else
                 GRP=":${DOCKERS[${CNTR},USER]/*:/}"
             fi
        fi
        for ITEM in ${DOCKERS[${CNTR},DATA]}     # check and correct data directories ownerships
        do
            ITEM=${ITEM/:*/} ; ITEM=${DOCKERS[${CNTR},HOME]}${ITEM/\/*\//\/}
            if ! [ -d "${ITEM}" ]
            then
                if ! SET_DIRECTORY "${ITEM}" ${DOCKERS[${CNTR},USER]/:*/}
                then
                    MESSAGE ERROR "Unable to create and user ownership container directory '${ITEM}'."
                else
                    MESSAGE INFO "Creating directory '${ITEM}' for container ${CNTR} with userid '$(echo ${DOCKERS[${CNTR},USER]:-root} | sed 's/:.*//')'."
                fi
            fi
        done
        if [ -n "${DOCKERS[$CNTR},AFTER]}" ]      # notify info after configuration
        then
            MESSAGE NOTICE "Some hints after installation:${DOCKERS[$CNTR,AFTER]}."
        fi
    fi

    # check if internet port is not used by others
    local PRT PRTS=
    for PRT in $( echo "${DOCKERS[${CNTR},PORT]}" | grep ':' | sed -e 's/--publish//' -e 's/=//' -e 's/:.*//' -e 's/ /\n/g' | sort | uniq)
    do
	PRT=${PRT/:*/}
        # in case someone else is using the web port
	if LISTENING ${PRT}
	then
	    if [ -z "${RESTORE[${CNTR}]}" ]       # container needs to be restored
            then
	        MESSAGE WARN "Check it. Is docker container '${CNTR}' with webGUI listening on port '${PRT}'?"
	        MESSAGE WARN "$(ss -HlpT 'sport = :${PRT}')\nFor now we just try restart the container '${CNTR}'."
                MESSAGE WARN "Will just restarting container '${CNTR}'."
                ${SUDO}docker restart "${CNTR}"
	        return 0
	    fi
	fi
        PRTS+=" $PRT"
    done
    if [ -n "${RESTORE[${CNTR}]}" ]
    then
	RESTORE_DATA ${CNTR}
    fi

    # configure zigbee2mqtt configuration.yaml for operational container and webGUI
    if ! CONFIG_CHECK ${CNTR:-None}
    then
        MESSAGE WARN "Cannot run docker container '$CNTR'.\nSkip to run container."
        return 1
    fi

    # inform user about effective user of the container
    if [ -n "${DOCKERS[${CNTR},USER]/:*/}" ]   # ownership problems? See zigbee2mqtt dongle notes!
    then
         MESSAGE NOTICE "Container '$CNTR' uses group $(groups ${DOCKERS[${CNTR},USER]/:*/} | sed -e 's/:/with/' -e 's/users/as users/')."
    else
         MESSAGE NOTICE "Container '${CNTR}' will run as user '${DOCKERS[${CNTR},USER]:-anonymous}'."
    fi

    # generate CLI command to start docker containter
    cat >${TMP_DIR}/run_command <<EOF
#!/bin/bash
# create a new docker container ${CNTR}
# created from script ${SCRIPT} on $(date +%Y-%m-%dT%H:%M) by $USER
# Use envirionment variable DEBUG=log to run in interactive logging modus. Default: detached.
# Use environment variable DEBUG=bash to run in interactive bash commands modus.
DEBUG=$DEBUG       # for logging and bash interactive modus.
if ${SUDO}docker ps --all --format 'table {{.Names}}' | grep -q ${CNTR}
then    # if container is available, remove it
    echo "Container ${CNTR} is already available! Container is stopped and removed." >$VERBOSE
    ${SUDO}docker stop ${CNTR} >/dev/null # if running stop it
    ${SUDO}docker rm ${CNTR} >/dev/null
fi
# Run container '${CNTR}' command:"  or use docker compose.yaml file
if [ -f "${DOCKERS[$CNTR,HOME]}/compose.yaml" ]
then
    MODUS=--detach=true
    if [ -n "\$DEBUG" ]
    then
        MODUS=--detach=false
        echo "Run container $CNTR in interactive/attached modus via via 'docker compose'." >$VERBOSE
    else
        echo "Run container $CNTR in detached modus via CLI 'docker compose'." >$VERBOSE
    fi
    ${SUDO}docker compose -f ${DOCKERS[$CNTR,HOME]}/compose.yaml up \$MODUS
else
    # docker will be run default deamonized with: run --detach and --restart arguments:
    MODUS="--detach --restart=unless-stopped"
    if [ -n "\$DEBUG" ]
    then
        MODUS="--interactive --tty"
        echo "Run container $CNTR in interactive/attached \$DEBUG modus via CLI 'docker run'." >$VERBOSE
    else
        echo "Running container $CNTR in detached modus via CLI 'docker run'." >$VERBOSE
    fi
    ${SUDO}docker run \$MODUS \\
EOF
    # collect  and add docker run command options
    CMD_RUN_CNTR ${CNTR}  | awk '{ printf("    %s \\\n",$0);}' >>${TMP_DIR}/run_command
    echo -e '    ${DEBUG/log*/}\nfi' >>${TMP_DIR}/run_command  # maybe should last line is image

    # START the docker container
    if ${SUDO}docker ps --all --format 'table {{.Names}}' | grep -q ${CNTR}
    then                                       # if container is available, remove it
	MESSAGE NOTICE "Container ${CNTR} is already available! Container is stopped and removed."
    fi

    # how to check running container? e.g.
    # docker run -it --entrypoint /bin/sh --device /dev/ttyACM0 koenkk/zigbee2mqtt -c "ls -halt /dev/ttyACM0"
    # or run the run arguments without detaich and restart option.
    # Alternative run docker exec -i conatainer_name on running container.

    if ! ${SUDO}bash ${DEBUG/[0-9a-zA-Z]*/-x} $TMP_DIR/run_command >/dev/null 2>$VERBOSE
    then
         MESSAGE ERROR "Failed to start running '$CNTR' container."
	 MESSAGE NOTICE "Try 'docker stop $CNTR', 'docker rm $CNTR' to clean up.
   CLI logging for cause: try setup.sh script in $CTNTR home directory
       with run options: --interactive --tty
       without run options: --detach and --restart.
       And stop/remove the container (docker rm ${CNTR}).
    Or clean up with 'sh $SCRIPT purge ${CNTR}'."
	 rm -f $TMP_DIR/run_command
         STATUS+=1
    else
	for PRT in $PTRS                        # check if exported ports are remotely available
	do
            if [ -n "$PRT" ] && ! LISTENING "$PRT" REMOTE 
            then
                MESSAGE NOTICE "Container $CNTR seems not yet to listen to remote connections on port $PRT."
	        STATUS+=1
	    fi
        done
	chmod +x ${TMP_DIR}/run_command
	${SUDO:-sudo} mv -i ${TMP_DIR}/run_command ${DOCKERS[$CNTR,HOME]}/setup.sh
        MESSAGE DEBUG "Run container '${CNTR}' CLI command: ${DOCKERS[$CNTR,HOME]}/setup.sh"
    fi
    rm -f $TMP_DIR/run_command

    # generate docker compose file for docker compose up -f compose.yml -d
    if docker compose alpha generate ${CNTR} 2>/dev/null >${TMP_DIR}/compose.yaml 2>/dev/null
    then
	${SUDO:-sudo} mv ${TMP_DIR}/compose.yaml ${DOCKERS[$CNTR,HOME]}/compose.yaml
	MESSAGE NOTICE "Created docker (experimental) compose file: DOCKERS[$CNTR,HOME]/compose.yaml"
    fi
    MESSAGE NOTICE "Created and running docker container ${Blue}$CNTR${Reset}."
    MESSAGE NOTICE "Exported ports:${Blue}${PRTS:- None}${Reset}."
    PRT=${DOCKERS[$CNTR,USER]/:/, GUID }
    if echo "${DOCKERS[$CNTR,OPTIONS]}" | grep -q 'privileged'
    then
	PRT="super user ${Red}root${Reset}"
    fi
    MESSAGE NOTICE "Container runs with effective user: ${PRT:-${Blue}anonymous${Reset}}."
    if (( $STATUS == 0 ))
    then
        INSTALLED[${CNTR}]="${Green}Installed container $CNTR${Reset}, effective user ${PRT:-anonymous}, ports ${PRTS:- None}."
    else
	INSTALLED[${CNTR}]="${Red}Failed to install container $CNTR${Reset}."
    fi
    return $STATUS
}

# ############################################################
# ############# PURGE container image ########################
# ############################################################
# check if docker is installed and running
# remove container and image from the system and eventualy docker
function PURGE_IMAGE(){
    local TYPE=$1 ONE SRVRS CNTRS ; shift
    for ONE in $@
    do
        case "${ONE,,}" in
        all)
             PURGE_IMAGE $TYPE $(echo ${!DOCKERS[@]} | sed 's/,[A-Z][A-Z]*//g' | \
                awk '{ for(i=1;i<=NF;i++){print $i};}' | sort | uniq )
             PURGE_IMAGE $TYPE mosquitto docker
             return $?
        ;;
        default)
             PURGE_IMAGE $TYPE ${DEFAULTS,,}
        ;;
        docker|mosquitto)   # system OS service
            SRVRS+=" ${ONE,,}"
        ;;
        *)                  # docker container
            CNTRS+=" ${ONE,,}"
        ;;
        esac
    done

    if [ -n "$CNTRS" ] && ! pgrep -u root dockerd >/dev/null # docker deamon should be alive
    then
        MESSAGE EMERGE "Docker service deamon is not alive!"
    else
        for ONE in $CNTRS
        do
            MESSAGE WARN "Docker container and image '$ONE' will be purged from the system!"
            REMOVE_IMAGE "${ONE,,}"
            if [ $TYPE = delete ] ; then DELETE_CONTAINER "{ONE,,}" ; fi
        done
    fi
    # no containers left purge docker installation
    if [ -n "$SRVRS" ]
    then
        for ONE in $SRVRS
        do
            if [ ${ONE} = docker ]
            then
                if echo $(${SUDO}docker ps --format '{{.ID}}' 2>/dev/null) | grep -q '[a-f0-9]' 
                then
                    MESSAGE EMERGE "Purge first all docker images on this system!"
                    return 1
                else
                    ${SUDO:-sudo} delgroup --quiet docker
                fi
            fi
            MESSAGE NOTICE "Stop and purge service '$ONE' from this system."
            ${SUDO:-sudo} systemctl --quiet disable ${ONE,,}
            ${SUDO:-sudo} systemctl --quiet stop ${ONE,,}
            ${SUDO:-sudo} apt purge ${ONE,,}
            if [ -n "${DOCKERS[$ONE,USER]/:*/}" ] && grep -q "${DOCKERS[$ONE,USER]/:*/}:" /etc/passwd
            then
                MESSAGE NOTICE "Remove user:group ${DOCKERS[$CNTR,USER]} home and local data from system."
                ${SUDO:-sudo} deluser --quiet --logmsglevel info --remove-home ${DOCKERS[$CNTR,USER]/:*/}
            fi
        done
    fi
    return $?
}

# check if dependant container or service is available, if not add them
CONTAINERS=            # unordered list of services/containers to install
DEAMONS=
function ADD_ITEM() {
   local RTS=1 ITEM=${1,,} TYPE
   if [ -n "$2" ] ; then TYPE=" (e.g. $2 depends on it)" ; fi
   if echo ${CONTAINERS} ${DEAMONS} | grep -q "^${ITEM}$" ; then return 0 ; fi  # already added
   # is it a supported docker container?
   if echo ${!DOCKERS[@]} | awk '{for(i=1;i <= NF;i++){sub(",[A-Z]*","",$i); print $i;}}' | sort | uniq | grep -q "^${ITEM}$"
   then
       if ! systemctl --quiet is-active docker         # is docker installed and running?
       then
           ADD_ITEM docker ${ITEM}
       else   
           if ${SUDO}docker ps --format '{{.Names}}' | grep -q "${ITEM}"
           then
               MESSAGE DEBUG "Docker container ${ITEM}${TYPE} is ${Black}already installed and running${Reset}."
               if [ -n "$TYPE" ] ; then return 0 ; fi
           elif ${SUDO}docker inspect "${DOCKERS[${ITEM},IMAGE]:-None}" 2>/dev/null >/dev/null
           then
               MESSAGE DEBUG "Docker container ${ITEM}${TYPE} ${Black}image is installed${Reset} but ${Red}not active${Reset}."
               if [ -n "$TYPE" ] ; then return 0 ; fi
           fi
       fi
       if ! echo $CONTAINERS | grep -q ${ITEM}
       then
           MESSAGE NOTICE "Adding docker container '${ITEM}'${TYPE}."
           CONTAINERS+="
${ITEM}"
           CHK_DEPENDANT "${ITEM}"
       fi
       RTS=
   fi
   # is it a supported system service?
   if echo ${!SERVICES[@]} | awk '{for(i=1;i <= NF;i++){sub(",[A-Z]*","",$i); print $i;}}' | sort | uniq | grep -q "^${ITEM}$"
   then
       if systemctl --quiet is-active ${ITEM}
       then
           MESSAGE DEBUG "System service ${ITEM}${TYPE} is already installed and running. Skipped."
           return 0                                    # already installed and running
       fi
       if ! echo ${DEAMONS} | grep -q ${ITEM}
       then
           MESSAGE NOTICE "Adding system service '${ITEM}'${TYPE}."
           DEAMONS+="
${ITEM}"
           CHK_DEPENDANT "${ITEM}"
       fi
       RTS=
   fi
   if [ -n "$RTS" ]
   then
       MESSAGE WARN "Container or system service '$1' is not configured. Skipped."
       return 1
   fi
   return 0
}

# add containers or services on which the argument depends
function CHK_DEPENDANT() {
    local CHK
    for CHK in ${DOCKERS[$1,DPTS]} ${SERVICES[$1,DPTS]}
    do
        ADD_ITEM "$CHK" ${1,,}
    done
}

# ***************** end of routines ****************************
# **************************************************************

# *************** handle command line options
# get command line options -help, -debug,  ...
while true
do
    if [ -z "$1" ] || [ "${1/#-*[hH]*/help}" = "help" ]
    then
        shift
        HELP $@
        exit 0
    elif [ "${1/#-*[dD]*/debug}" = "debug" ]
    then
        shift
        MSG=DEBUG                          # message level to all
        set -x                             # show statements as executed by script
    elif [ "${1/#-*[lL]*/level}" = "level" ]
    then
        MSG=${1/*=/} ; MSG=${MSG^^}
        if [ -z "${LEVEL[$MSG]}" ]
        then
            echo "Unknown level: $MSG" >/dev/stderr
            exit 1
        fi
        shift
    elif [ "${1,,}" = dump ]               # create a tar dump of a container data
    then
	shift
	if ! GET_DUMP $@
	then
	    MESSAGE ERROR "Failed to create tar dump of $? container(s)."
	    exit 1
	fi
	exit 0
    else
        break
    fi
done

if [ -z "$1" ]   # no action, publish help info
then
    HELP
    exit 0
fi

# collect list of containers and services to manipulate

# check if first arg is defining operational modus
while [ -n "${1}" ]
do
    case "${1,,}" in
        purge|delete)                               # purge/delete from system
            shift
            while [ -n "${1,,}" ]
            do
                if [ -n "${1,,}" ]
                then 
                    if ! PURGE_IMAGE ${1,,} "${1,,}" ; then exit 1 ; fi
                    shift
                fi
            done
            break
        ;;
        restore)
	    shift
	    while [ -n "${1,,}" ]
	    do
	        if [ -n "${1,,}" ]
                then
		     if ! GET_RESTORE_DATA "${1,,}"
		     then
			 MESSAGE ERROR "Unable to find backup data file or not supported container ${1,,}. Skipped."
		     else
			 ADD_ITEM ${1,,}
		     fi
		fi
		shift
	    done
	;;
        default*)                                    # install or update defaults
            # initialisation variables
            for ITEM in ${DEFAULTS}                 # add defaults
            do
                ADD_ITEM ${ITEM}
            done
            shift
        ;;
        install|update)                             # add force?
            shift
        ;;
        *)
            ADD_ITEM ${1,,}
            shift
        ;;
    esac
done

# ************************************* MAIN the work horse ***************************
# and now install or update the docker containers
declare -i RTS=0

if [ -n "${DEAMONS}" ]                                # install/update first the deamons
then
	MESSAGE INFO "Installing system service(s): $(echo ${DEAMONS})."
    for ITEM in ${DEAMONS}                            # ****** system service handling
    do
       if ! ADD_SERVICE "$ITEM"
       then
           MESSAGE WARN "Install system OS service '$ITEM' is skipped."
           RTS+=1
       fi
    done
fi

if [ -n "${CONTAINERS}" ]                             # install/update docker containers
then
    if groups | grep -q -P "\sdocker" && systemctl --quiet is-active docker
    then
        SUDO=                     # docker is running and docker group is added for $USER
    fi
    MESSAGE INFO "Installing docker container(s): $(echo ${CONTAINERS})."
    for ITEM in ${CONTAINERS}                         # ****** docker containers handling
    do
       if ! ADD_CONTAINER "${ITEM,,}"
       then
           MESSAGE WARN "Install/update docker container '${ITEM,,}' is skipped."
           RTS+=1
       fi
    done
fi

# ready, work done
if (( "${#INSTALLED[@]}" > 0 ))
then
    MESSAGE NOTICE "Installation overview:"
    for ITEM in ${!INSTALLED[*]}
    do
       MESSAGE WARN "${INSTALLED[$ITEM]}"
    done
fi
if (( $RTS > 0 ))
then
    MESSAGE ERROR "Unable to install/update one of $RTS services and docker containers."
fi
exit $RTS
