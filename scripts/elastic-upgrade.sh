#!/usr/bin/env bash

# 3 options:
# - docker compose
# - docker "simple"
# - classic installation
#   > macOS
#   > debian/ubuntu
#   > other linux


config()
{
  echo "detecting curl..."
  if ! command -v curl
  then
    echo "Please install curl before running this script."
    echo "curl was not found, exiting..."
    exit 1
  fi
  echo "checking memory..."
  mem=$(free -mt | grep Total | awk '{print $2}')
  if [ "$mem" -lt 4000 ]
  then
    read -rp "Not enough memory to perform upgrade. Would you like to add the necessary swap? (y/n) " swap </dev/tty
    if [ "$swap" = "y" ]
    then
      local swap_value=$((4096-$mem))
      sudo fallocate -l "${swap_value}M" /swapfile
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile
      sudo swapon /swapfile
      echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
      echo 'vm.swappiness = 10' | sudo tee -a /etc/sysctl.conf
      echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf
    else
      echo "Please upgrade memory to 4GB or more to allow the upgrade to run."
      free -h
      exit 7
    fi
  fi
  FM_PATH=$(pwd)
  TYPE="NOT-FOUND"
  read -rp "Is fab-manager installed at \"$FM_PATH\"? (y/n) " confirm </dev/tty
  if [ "$confirm" = "y" ]
  then
    if [ -f "$FM_PATH/config/application.yml" ]
    then
      ES_HOST=$(cat "$FM_PATH/config/application.yml" | grep ELASTICSEARCH_HOST | awk '{print $2}')
    elif [ -f "$FM_PATH/config/env" ]
    then
      ES_HOST=$(cat "$FM_PATH/config/env" | grep ELASTICSEARCH_HOST | awk '{split($0,a,"="); print a[2]}')
    fi
    ES_IP=$(getent ahostsv4 "$ES_HOST" | awk '{ print $1 }' | uniq)
  else
    echo "Please run this script from the fab-manager's installation folder"
    exit 1
  fi
}

test_docker_compose()
{
  if [[ -f "$FM_PATH/docker-compose.yml" ]]
  then
    docker-compose ps | grep elastic
    if [[ $? = 0 ]]
    then
      TYPE="DOCKER-COMPOSE"
      local container_id=$(docker-compose ps | grep elastic | awk '{print $1}')
      ES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_id")
    fi
  fi
}

test_docker()
{
  if command -v docker
  then
    docker ps | grep elasticsearch:1.7
    if [[ $? = 0 ]]
    then
      local containers=$(docker ps | grep elasticsearch:1.7)
      docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(echo "$containers" | awk '{print $1}') | grep "$ES_IP"
      if [[ $? = 0 ]]; then TYPE="DOCKER"; fi
    fi
  fi
}

test_classic()
{
  if [ "$ES_IP" = "127.0.0.1" ] || [ "$ES_IP" = "::1" ]
  then
    whereis -b elasticsearch | grep "/"
    if [[ $? = 0 ]]; then TYPE="CLASSIC"; fi
  fi
}

test_running()
{
  local http_res=$(curl -I "$ES_IP:9200" 2>/dev/null | head -n 1 | cut -d$' ' -f2)
  if [ "$http_res" = "200" ]
  then
    echo "ONLINE"
  else
    echo "OFFLINE"
  fi
}

test_version()
{
  local version=$(curl "$ES_IP:9200"  2>/dev/null | grep number | awk '{print $3}')
  case "$version" in
  *1.7*)
    echo "1.7"
    ;;
  *2.4*)
    echo "2.4"
    ;;
  *5.6*)
    echo "5.6"
    ;;
  *6.2*)
    echo "6.2"
    ;;
  *)
    echo "$version"
  esac
}

detect_installation()
{
  echo "Detecting installation type..."

  test_docker_compose
  if [[ "$TYPE" = "DOCKER-COMPOSE" ]]
  then
    echo "Docker-compose installation detected."
  else
    test_docker
    if [[ "$TYPE" = "DOCKER" ]]
    then
    echo "Classical docker installation detected."
    else
      test_classic
      if [[ "$TYPE" = "CLASSIC" ]]
      then
        echo "Local installation detected on the host system."
      fi
    fi
  fi

  if [[ "$TYPE" = "NOT-FOUND" ]]
  then
    echo "ElasticSearch 1.7 was not found on the current system, exiting..."
    exit 2
  else
    echo -n "Detecting online status... "
    if [[ "$TYPE" != "NOT-FOUND" ]]
    then
        STATUS=$(test_running)
        echo "$STATUS"
    fi
  fi
}

error_index_status()
{
  echo "Your elasticSearch installation contains indices which states are not \"green\", but this cannot be solved automatically."
  echo "Please solve theses status before continuing..."
  curl "$ES_IP:9200/_cat/indices?v" 2>/dev/null | grep --color -E "yellow|red|$"
  exit 6
}

ensure_initial_status_green()
{
  echo "Checking status of your elasticSearch indices..."
  local state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
  if [ "$state" != "green" ]
  then
    local replicas=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $5}' | sort | uniq)
    if [ "$replicas" != "0" ]
    then
      local indices=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $3}')
      for index in $indices # do not surround $indices with quotes
      do
        curl -XPUT "$ES_IP:9200/$index/_settings" -H 'Content-Type: application/json' -d '{
          "index": {
            "number_of_replicas": 0
          }
        }'
      done
      local final_state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
      if [ "$final_state" != "green" ]; then error_index_status; fi
    else
      error_index_status
    fi
  fi
}

wait_for_online()
{
  STATUS=$(test_running)
  while [ "$STATUS" != "ONLINE" ]
  do
    sleep 1
    STATUS=$(test_running)
  done
}

upgrade_compose()
{
  local current=$1
  local target=$2
  echo -e "\nUpgrading docker-compose installation from $current to $target..."
  docker-compose stop elasticsearch
  docker-compose rm -f elasticsearch
  sed -i.bak "s/image: elasticsearch:$current/image: elasticsearch:$target/g" "$FM_PATH/docker-compose.yml"
  docker-compose pull
  docker-compose up -d
  wait_for_online
  local version=$(test_version)
  if [ "$STATUS" = "ONLINE" ] && [ "$version" = "$target" ]; then
    echo "Migration to elastic $target was successful."
  else
    echo "Unable to find an active ElasticSearch $target instance, something may have went wrong, exiting..."
    echo "status: $STATUS, version: $version"
    exit 4
  fi
}

upgrade_docker()
{
  local current=$1
  local target=$2
  echo -e "\nUpgrading docker installation from $current to $target..."
  local containers=$(docker ps | grep "elasticsearch:$current")
  # get container id
  local id=$(docker inspect -f '{{.Id}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(echo "$containers" | awk '{print $1}') | grep "$ES_IP" | awk '{print $1}')
  # get container name
  local name=$(docker inspect -f '{{.Name}}' "$id" | sed s:^/::g)
  # get container network name
  local network=$(docker inspect -f '{{.NetworkSettings.Networks}}' "$id" | sed 's/map\[\(.*\):0x[a-f0-9]*\]/\1/')
  # get container mapping to data folder
  local mounts=$(docker inspect -f '{{.Mounts}}' "$id" | sed 's/} {/\n/g' | sed 's/^\[\?{\?bind[[:blank:]]*\([^[:blank:]]*\)[[:blank:]]*\([^[:blank:]]*\)[[:blank:]]*true \(rprivate\)\?}\?]\?$/-v \1:\2/g' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g')
  # stop current elastic
  docker stop "$name"
  docker rm -f "$name"
  # run target elastic
  docker pull "elasticsearch:$target"
  echo docker run --restart=always  -d --name="$name" --network="$network" --ip="$ES_IP" "$mounts" "elasticsearch:$target" | bash
  # check status
  wait_for_online
  local version=$(test_version)
  if [ "$STATUS" = "ONLINE" ] && [ "$version" = "$target" ]; then
    echo "Migration to elastic $target was successful."
  else
    echo "Unable to find an active ElasticSearch $target instance, something may have went wrong, exiting..."
    echo "status: $STATUS, version: $version"
    exit 4
  fi
}

unsupported_message()
{
  local version=$1
  echo "Automated upgrade of your elasticSearch installation is not supported on your system."
  echo "Please refer to your vendor's instructions to install ElasticSearch $version"
  echo "For more informations: https://www.elastic.co/guide/en/elasticsearch/reference/$version/setup-upgrade.html"
  exit 5
}

upgrade_classic()
{
  local target=$1
  local system=$(uname -s)
  case "$system" in
    Linux*)
      if [ -f /etc/os-release ]
      then
        . /etc/os-release
        if [ "$ID" = 'debian' ] || [[ "$ID_LIKE" = *'debian'* ]]
        then
          # Debian compatible
          echo -e "\nUpdating ElasticSearch to $target"
          wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
          case "$target" in
          "2.4")
            echo "deb http://packages.elastic.co/elasticsearch/2.x/debian stable main" | sudo tee /etc/apt/sources.list.d/elasticsearch-2.x.list
            ;;
          "5.6")
            echo "deb https://artifacts.elastic.co/packages/5.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-5.x.list
            ;;
          "6.2")
            echo "deb https://artifacts.elastic.co/packages/6.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-6.x.list
            ;;
          esac
          sudo apt-get update && sudo apt-get install --only-upgrade elasticsearch
          if command -v systemctl
          then
            sudo systemctl restart elasticsearch.service
          else
            sudo /etc/init.d/elasticsearch restart
          fi
        else
          unsupported_message
        fi
      fi
      ;;
    Darwin*)
      # Mac OS X
      brew update
      case "$target" in
      "2.4")
        brew install homebrew/versions/elasticsearch24
        ;;
      "5.6")
        brew install homebrew/versions/elasticsearch56
        ;;
      "6.2")
        brew install homebrew/versions/elasticsearch62
        ;;
      esac
      ;;
    *)
      unsupported_message
      ;;
  esac
  # check status
  wait_for_online
  local version=$(test_version)
  if [ "$STATUS" = "ONLINE" ] && [ "$version" = "$target" ]; then
    echo "Migration to elastic $target was successful."
  else
    echo "Unable to find an active ElasticSearch $target instance, something may have went wrong, exiting..."
    echo "status: $STATUS, version: $version"
    exit 4
  fi
}

reindex_indices()
{
  # todo get index/_mapping then put index/_mapping
  local indices=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $3}')
  for index in $indices # do not surround $indices with quotes
  do
    local migration_index="$index""_$1"
    curl -XPUT "http://$ES_IP:9200/$migration_index/" -d '{
      "settings" : {
        "index" : {
          "number_of_shards": 1,
          "number_of_replicas": 0,
          "refresh_interval": -1
        }
      }
    }'
    curl -XPOST "$ES_IP:9200/_reindex?pretty" -H 'Content-Type: application/json' -d '{
      "source": {
        "index": "'"$index"'"
      },
      "dest": {
        "index": "'"$migration_index"'"
      }
    }'
  done
  echo "Indices are reindexing, waiting to finish..."
  local state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
  while [ "$state" != "green" ]
  do
    sleep 1
    state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
  done
  echo "Reindex completed, deleting previous index..."
  for index in $indices # do not surround $indices with quotes
  do
    curl -XDELETE "$ES_IP:9200/$index?pretty"
  done
}

reindex_final_indices()
{
  local previous=$1
  local indices=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $3}')
  for index in $indices # do not surround $indices with quotes
  do
    local final_index=$(echo "$index" | sed "s/\(.*\)_$previous$/\1/")
    curl -XPUT "http://$ES_IP:9200/$final_index"
    curl -XPOST "$ES_IP:9200/_reindex?pretty" -H 'Content-Type: application/json' -d '{
      "source": {
        "index": "'"$index"'"
      },
      "dest": {
        "index": "'"$final_index"'"
      }
    }'
  done
  echo "Indices are reindexing, waiting to finish..."
  local state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
  while [ "$state" != "green" ]
  do
    sleep 1
    state=$(curl "$ES_IP:9200/_cat/indices" 2>/dev/null | awk '{print $1}' | sort | uniq)
  done
  echo "Reindex completed, deleting previous index..."
  for index in $indices # do not surround $indices with quotes
  do
    curl -XDELETE "$ES_IP:9200/$index?pretty"
  done
}

start_upgrade()
{
  # $1: current version
  # $2: target version
  case "$TYPE" in
  "DOCKER-COMPOSE")
    upgrade_compose $1 $2
    ;;
  "DOCKER")
    upgrade_docker $1 $2
    ;;
  "CLASSIC")
    upgrade_classic $2
    ;;
  *)
    echo "Unexpected ElasticSearch installation $TYPE"
    exit 3
  esac
}

upgrade_elastic()
{
  config
  detect_installation
  read -rp "Continue with upgrading? (y/n) " confirm </dev/tty
  if [[ "$confirm" = "y" ]]
  then
    ensure_initial_status_green
    start_upgrade '1.7' '2.4'
    reindex_indices '24'
    start_upgrade '2.4' '5.6'
    reindex_indices '56'
    start_upgrade '5.6' '6.2'
    reindex_final_indices '56'
  fi
}

upgrade_elastic "$@"
