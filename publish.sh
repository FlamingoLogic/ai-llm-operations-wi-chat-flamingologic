#!/bin/bash

################################################################################
# NOTE: DO NOT EXPOSE THIS SERVER TO THE INTERNET!!! IT SHOULD BE HELD BEHIND #
# A FIREWALL AND ONLY EXPOSED TO TRUSTED RESOURCES.                          #
################################################################################

## This script assumes Debian 12 or Ubuntu 24.04
## This would normally be deployed in a NixOS environment; however, creating a generic script is more accessible to most Linux users
## This script has two parts:
##   - Top part helps configure a server ("init")
##   - Bottom part is the script that runs every time you publish ("rebuild")
## This script configures nginx and mdbook with IP. You will need to update with URL if needed (see theme/head.hbs)

## TODO:
# - run https://github.com/chuboe/chuboe-system-configurator
# - ensure running from user with sudo privileges
# - add https cert in nginx
# - update the below variables labeled with ###change-me###

#### More Repository Notes ####
# The script assumes there are multiple repositories (or at least accounts for this scenario)
# Each repository:
#   - is a book or collection of knowledge (has src directory)
#   - has its own book.toml
#   - can have multiple aichat airole files/ttyd (csr, mgr, etc...)
#   - note: we can put [FlamingoLogic] variables in the book.toml without conflict
#### end More Repository Notes ####

function graceful_exit {
  echo -e "Exiting due to an error occurring at $(TZ=US/Eastern date '+%m/%d/%Y %H:%M:%S EST.')\n"
  echo -e "Some results before the error may have been logged to $LOG_FILE\n"
  echo -e "Here is the error message: $1\n"
  exit 1
}

# Validations
echo "Running sudo validation check..."
sudo ls &>/dev/null || graceful_exit "Current user does not have sudo abilities"

#### Variables used by all parts of script ####
declare -A SC_VARIABLES
SC_SCRIPT_DIR_NAME=$(readlink -f "$0")
SC_SCRIPT_DIR=$(dirname "$SC_SCRIPT_DIR_NAME")
SC_SCRIPT_NAME=$(basename "$0")
OS_USER=$(id -u -n)
OS_USER_GROUP=$(id -g -n)
CHAT_USER="cathy"  ###change-me###
SC_VARIABLES[CHAT_USER]=$CHAT_USER

WI_ROOT_DIR=/opt/work-instruction
GH_URL="https://github.com"
GH_PROJECT="FlamingoLogic"  ###change-me###
GH_REPO="ai-llm-operations-wi-chat-flamingologic"  ###change-me###
WI_URL=$GH_URL/$GH_PROJECT/$GH_REPO
WI_REPO_DIR=$WI_ROOT_DIR/$GH_PROJECT/$GH_REPO
WI_SRC="src-work-instructions"  ###change-me###
WI_SRC_DIR=$WI_REPO_DIR/$WI_SRC
AI_CONFIG=config-openai.yaml  ###change-me###
AI_ROLE_STARTER=airole-starter
AI_ROLE_STARTER_MD=$AI_ROLE_STARTER.md
AI_RAG_ALL=wi-rag-all
WS_SERVICE_NAME=$GH_REPO-$AI_ROLE_STARTER
WS_SERVICE_NAME_TTYD=ttyd-$WS_SERVICE_NAME
TTYD_PORT=7681
MY_IP=$(hostname -I | awk '{print $1}')

# Output property variables
echo
echo "Property Variables Set:"
for key in "${!SC_VARIABLES[@]}"; do
  echo "$key=\"${SC_VARIABLES[$key]}\""
done

#### Uncomment the below to reset during testing ####
# sudo systemctl disable $WS_SERVICE_NAME.service
# sudo systemctl stop $WS_SERVICE_NAME.service
# sudo rm -rf /etc/systemd/system/$WS_SERVICE_NAME.service
# sudo systemctl daemon-reload
# sudo rm -rf /var/www/$WS_SERVICE_NAME
# sudo rm -f /etc/nginx/sites-available/$WS_SERVICE_NAME
# sudo rm /etc/nginx/sites-enabled/$WS_SERVICE_NAME
# sudo rm -rf /opt/work-instruction/
# sudo deluser cathy; sudo rm -rf /home/cathy/
# sudo rm -rf /tmp/ttyd/
# sudo rm /etc/cron.d/cron*
# git reset --hard; git pull

#### PART ONE: INIT CONFIGURATION ####
if [[ $1 == "init" ]]; then

  echo "Configuring system locale..."
  sudo locale-gen en_US.UTF-8
  sudo update-locale LANG=en_US.UTF-8 LANGUAGE=en_US LC_ALL=en_US.UTF-8
  export LANG=en_US.UTF-8
  export LANGUAGE=en_US
  export LC_ALL=en_US.UTF-8

  echo "Creating system user: $CHAT_USER"
  sudo adduser --disabled-password --gecos "" $CHAT_USER

  echo "Cloning repository..."
  sudo mkdir -p $WI_ROOT_DIR/$GH_PROJECT/
  sudo git clone $WI_URL $WI_REPO_DIR
  for key in "${!SC_VARIABLES[@]}"; do
    echo "$key=\"${SC_VARIABLES[$key]}\"" | sudo tee -a $WI_REPO_DIR/config.properties
  done

  echo "Copying utilities..."
  sudo cp -r $SC_SCRIPT_DIR/util $WI_REPO_DIR/
  sudo cp $SC_SCRIPT_DIR/publish.sh $WI_REPO_DIR/.
  sudo sed -i "s|WI_REPO_DIR|$WI_REPO_DIR|g" $WI_REPO_DIR/util/cron-file
  sudo mv $WI_REPO_DIR/util/cron-file $WI_REPO_DIR/util/cron-$GH_PROJECT-$GH_REPO

  echo "Configuring aichat..."
  sudo mkdir -p /home/$CHAT_USER/.config/aichat/roles/
  sudo cp $WI_REPO_DIR/util/$AI_CONFIG /home/$CHAT_USER/.config/aichat/config.yaml
  sudo ln -s $WI_SRC_DIR/$AI_ROLE_STARTER_MD /home/$CHAT_USER/.config/aichat/roles/$AI_ROLE_STARTER_MD
  sudo chown -R $CHAT_USER:$CHAT_USER /home/$CHAT_USER/

  echo "Staging RAG content..."
  $WI_REPO_DIR/util/stage.sh

  echo "Installing ttyd..."
  cd /tmp/
  sudo apt-get update
  sudo apt-get install -y build-essential cmake git libjson-c-dev libwebsockets-dev
  git clone https://github.com/tsl0922/ttyd.git
  cd ttyd && mkdir build && cd build
  cmake ..
  make && sudo make install

  echo "Setting up ttyd service..."
  sudo sed -i "s|CHAT_USER|$CHAT_USER|g" $WI_REPO_DIR/util/ttyd.service
  sudo sed -i "s|WI_REPO_DIR|$WI_REPO_DIR|g" $WI_REPO_DIR/util/ttyd.service
  sudo sed -i "s|CHAT_USER|$CHAT_USER|g" $WI_REPO_DIR/util/ai-launcher.sh
  sudo sed -i "s|AI_RAG_ALL|$AI_RAG_ALL|g" $WI_REPO_DIR/util/ai-launcher.sh
  sudo sed -i "s|AI_ROLE_STARTER|$AI_ROLE_STARTER|g" $WI_REPO_DIR/util/ai-launcher.sh
  sudo cp $WI_REPO_DIR/util/ttyd.service $WI_REPO_DIR/util/$WS_SERVICE_NAME.service
  sudo mv $WI_REPO_DIR/util/$WS_SERVICE_NAME.service /etc/systemd/system/$WS_SERVICE_NAME.service
  sudo systemctl daemon-reload
  sudo systemctl enable $WS_SERVICE_NAME.service
  sudo systemctl start $WS_SERVICE_NAME.service

  echo "Generating self-signed certificate..."
  country="AU"
  state="SA"
  locality="Adelaide"
  organization="flamingo-logic"
  organizationalunit="training"
  commonname="flamingo"
  email="admin@flamingologic.com"

  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/C=$country/ST=$state/L=$locality/O=$organization/OU=$organizationalunit/CN=$commonname/emailAddress=$email" \
    -keyout /etc/ssl/private/nginx-selfsigned.key \
    -out /etc/ssl/certs/nginx-selfsigned.crt

  echo "Installing and configuring nginx..."
  sudo apt install nginx -y
  sudo mkdir -p /var/www/$WS_SERVICE_NAME
  sudo cp $WI_REPO_DIR/util/404.html /var/www/.
  sudo chown -R www-data:www-data /var/www/
  sudo chmod -R 755 /var/www/
  sudo sed -i "s|WS_SERVICE_NAME_TTYD|$WS_SERVICE_NAME_TTYD|g" $WI_REPO_DIR/util/nginx-config
  sudo sed -i "s|WS_SERVICE_NAME|$WS_SERVICE_NAME|g" $WI_REPO_DIR/util/nginx-config
  sudo sed -i "s|TTYD_PORT|$TTYD_PORT|g" $WI_REPO_DIR/util/nginx-config
  sudo cp $WI_REPO_DIR/util/nginx-config $WI_REPO_DIR/util/$WS_SERVICE_NAME
  sudo mv $WI_REPO_DIR/util/$WS_SERVICE_NAME /etc/nginx/sites-available/$WS_SERVICE_NAME
  sudo ln -s /etc/nginx/sites-available/$WS_SERVICE_NAME /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo systemctl restart nginx

  echo "Updating site metadata..."
  sudo sed -i "s|GH_PROJECT|$GH_PROJECT|g" $WI_REPO_DIR/book.toml
  sudo sed -i "s|GH_REPO|$GH_REPO|g" $WI_REPO_DIR/book.toml
  sudo sed -i "s|MY_IP|$MY_IP|g" $WI_REPO_DIR/theme/head.hbs
  sudo sed -i "s|WS_SERVICE_NAME_TTYD|$WS_SERVICE_NAME_TTYD|g" $WI_REPO_DIR/theme/head.hbs

  echo "Publishing first version..."
  PUBLISH_DATE=`date +%Y%m%d`-`date +%H%M%S`
  cd $WI_REPO_DIR/
  sudo $WI_REPO_DIR/util/summary.sh
  sudo /usr/local/bin/mdbook build
  sudo rsync -a --delete wi/ /var/www/$WS_SERVICE_NAME/
  sudo chown -R www-data:www-data /var/www/$WS_SERVICE_NAME/
  sudo rm -rf /var/www/$WS_SERVICE_NAME/.obsidian/
fi
