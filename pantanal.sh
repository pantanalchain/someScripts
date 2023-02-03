#!/bin/bash

# Step 1: Install go1.8.0 if not already installed
if ! dpkg -s golang-go >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install golang-go
fi

# Step 2: Create directory "/pantanal"
if [ ! -d "/pantanal" ]; then
  sudo mkdir /pantanal
fi

# Step 3: Download and extract the repository
cd /pantanal
if [ ! -d "go-ethereum" ]; then
  sudo git clone https://github.com/pantanalchain/pantanal.git
fi
export PATH=$PATH:/pantanal/pantanal/build/bin
source /etc/profile

# Step 4: Compile using make
cd /pantanal/pantanal
sudo make

# Step 5: Copy binary to /usr/local/bin
sudo cp build/bin/geth /usr/local/bin

# Step 6: Change directory
cd ..

# Step 7: Create new account
echo "Enter password: "
read -s password
echo "$password" | sudo -S geth --Pantanal account new<<EOF
$password
$password
exit
EOF

# Step 8: Remove the existing data
sudo rm -rf ~/.ethereum/Pantanal/geth/ ~/.ethereum/Pantanal/history

# Step 9: Start geth
nohup  geth --Pantanal --port 30303 --miner.gasprice 5000000000 --http --http.addr 0.0.0.0 --http.corsdomain "*" --http.port "8545" --http.api "eth, net, web3, txpool, debug" --ws --ws.port 9545 --ws.addr 0.0.0.0 --ws.origins "*" --ws.api "web3, net, eth, txpool, debug" --maxpeers=100 --allow-insecure-unlock --syncmode full --gcmode archive >/dev/null 2>./geth0.log &


# Step 10: Start mine
if ps -ef | grep "geth" | grep "Pantanal" > /dev/null; then
echo "geth is running"
else
echo "geth is not running, waiting..."
while ! ps -ef | grep "geth" | grep "Pantanal" > /dev/null; do
sleep 1
done
echo "geth is running"
geth --Pantanal attach <<EOF
personal.unlockAccount(eth.accounts[0],"$password",0)
miner.start()
exit
EOF
fi


sudo ufw allow 8545
sudo ufw allow 9545
sudo ufw allow 30303
sudo ufw reload
