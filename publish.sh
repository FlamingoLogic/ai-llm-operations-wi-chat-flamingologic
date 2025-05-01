#!/bin/bash

################################################################################
# NOTE: DO NOT EXPOSE THIS SERVER TO THE INTERNET!!! IT SHOULD BE HELD BEHIND #
# A FIREWALL AND ONLY EXPOSED TO TRUSTED RESOURCES.                          #
################################################################################

function graceful_exit {
  echo -e "Exiting due to an error occurring at $(TZ=US/Eastern date '+%m/%d/%Y %H:%M:%S EST.')\n"
  echo -e "Here is the error message: $1\n"
  exit 1
}

echo "Running sudo validation check..."
sudo ls &>/dev/null || graceful_exit "Current user does not have sudo abilities"

#### Variables ####
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

echo
echo "Property Variables Set:"
for key in "${!SC_VARIABLES[@]}"; do
  echo "$key=\"${SC_VARIABLES[$key]}\""
done

#### INIT ####
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
  sudo chown -R $CHAT_USER:$CHAT_USER $WI_REPO_DIR
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
  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/C=AU/ST=SA/L=Adelaide/O=flamingo-logic/OU=training/CN=flamingo/emailAddress=admin@flamingologic.com" \
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
  sudo ln -sf /etc/nginx/sites-available/$WS_SERVICE_NAME /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo systemctl restart nginx

  echo "Updating site metadata..."
  sudo sed -i "s|GH_PROJECT|$GH_PROJECT|g" $WI_REPO_DIR/book.toml
  sudo sed -i "s|GH_REPO|$GH_REPO|g" $WI_REPO_DIR/book.toml
  sudo sed -i "s|MY_IP|$MY_IP|g" $WI_REPO_DIR/theme/head.hbs
  sudo sed -i "s|WS_SERVICE_NAME_TTYD|$WS_SERVICE_NAME_TTYD|g" $WI_REPO_DIR/theme/head.hbs

  echo "Publishing first version..."
  cd $WI_REPO_DIR || graceful_exit "Failed to enter repo directory."

  echo "📝 Generating SUMMARY.md"
  sudo bash -c "echo '# Summary' > '$WI_SRC_DIR/SUMMARY.md'"
  for file in "$WI_SRC_DIR"/*.md; do
    filename=$(basename "$file")
    [[ "$filename" == "SUMMARY.md" ]] && continue
    title=$(echo "$filename" | sed 's/-/ /g; s/.md$//; s/\b\(.\)/\u\1/g')
    sudo bash -c "echo '- [$title]($filename)' >> '$WI_SRC_DIR/SUMMARY.md'"
  done
  sudo chown $CHAT_USER:$CHAT_USER "$WI_SRC_DIR/SUMMARY.md"

  echo "🔧 Ensuring output directory is writable..."
  sudo mkdir -p "$WI_REPO_DIR/book"
  sudo chown -R $CHAT_USER:$CHAT_USER "$WI_REPO_DIR"
  
  sudo -u $CHAT_USER /usr/local/bin/mdbook build || graceful_exit "mdbook build failed"
  sudo rsync -a --delete book/ /var/www/$WS_SERVICE_NAME/
  sudo chown -R www-data:www-data /var/www/$WS_SERVICE_NAME/
fi

#### REBUILD ####
if [[ $1 == "rebuild" ]]; then
  echo "Rebuilding ChatDoco content..."

  SUMMARY_FILE="$WI_SRC_DIR/SUMMARY.md"

  echo "📝 Generating SUMMARY.md at: $SUMMARY_FILE"
  sudo bash -c "echo '# Summary' > '$SUMMARY_FILE'"
  for file in "$WI_SRC_DIR"/*.md; do
    filename=$(basename "$file")
    [[ "$filename" == "SUMMARY.md" ]] && continue
    title=$(echo "$filename" | sed 's/-/ /g; s/.md$//; s/\b\(.\)/\u\1/g')
    sudo bash -c "echo '- [$title]($filename)' >> '$SUMMARY_FILE'"
  done
  sudo chown $CHAT_USER:$CHAT_USER "$SUMMARY_FILE"

  echo "🔧 Ensuring output directory is writable..."
  sudo mkdir -p "$WI_REPO_DIR/book"
  sudo chown -R $CHAT_USER:$CHAT_USER "$WI_REPO_DIR"

  echo "🏗 Running mdbook build..."
  cd "$WI_REPO_DIR" || graceful_exit "Failed to enter repo directory."
  sudo -u $CHAT_USER /usr/local/bin/mdbook build || graceful_exit "mdbook build failed"

  echo "📁 Deploying to NGINX directory..."
  sudo rsync -a --delete book/ /var/www/$WS_SERVICE_NAME/
  sudo chown -R www-data:www-data /var/www/$WS_SERVICE_NAME/

  echo "✅ Rebuild and deployment complete."
fi
