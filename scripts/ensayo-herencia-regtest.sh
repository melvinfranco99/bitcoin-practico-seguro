#!/usr/bin/env bash
# Ensayo completo de una herencia con bloqueo de tiempo, en REGTEST:
# una red de pruebas privada donde tú fabricas los bloques. No toca tu nodo real ni dinero de verdad.
# Requisitos: Bitcoin Core 25 o superior (bitcoind y bitcoin-cli) y jq.
# Uso: bash ensayo-herencia-regtest.sh
set -euo pipefail
DIR="$HOME/ensayo-herencia"
mkdir -p "$DIR"
cli() { bitcoin-cli -regtest -datadir="$DIR" "$@"; }
mina() { cli generatetoaddress "$1" "$(cli -rpcwallet=padre getnewaddress)" >/dev/null; }

bitcoind -regtest -datadir="$DIR" -daemon -fallbackfee=0.0001 -listen=0
sleep 5
for w in padre llave llave_ana; do cli createwallet "$w" >/dev/null; done
mina 101
echo "1) Carteras creadas. Bloque actual: $(cli getblockcount)"

# Clave pública y privada (descriptor wpkh externo, sin el /0/*)
clave() { cli -rpcwallet="$1" listdescriptors ${2:-} | jq -r '.descriptors[] | select(.desc|startswith("wpkh(")) | select(.internal==false) | .desc' | sed 's/^wpkh(//; s/\/0\/\*).*//'; }
PADRE=$(clave llave); PADRE_PRIV=$(clave llave true)
ANA=$(clave llave_ana); ANA_PRIV=$(clave llave_ana true)

# En regtest usamos una altura de bloque en vez de una fecha: 20 bloques en el futuro
H=$(( $(cli getblockcount) + 20 ))
D=$(cli getdescriptorinfo "wsh(or_d(pk($PADRE/0/*),and_v(v:pk($ANA/0/*),after($H))))" | jq -r .descriptor)
echo "2) Descriptor de la hucha de Ana (se libera en el bloque $H):"
echo "   $D"

# Padre: cartera de herencia con su clave privada
cli -named createwallet wallet_name=herencia blank=true >/dev/null
DP="wsh(or_d(pk($PADRE_PRIV/0/*),and_v(v:pk($ANA/0/*),after($H))))"
cli -rpcwallet=herencia importdescriptors "[{\"desc\":\"$DP#$(cli getdescriptorinfo "$DP" | jq -r .checksum)\",\"timestamp\":\"now\"}]" >/dev/null
A=$(cli deriveaddresses "$D" "[0,0]" | jq -r '.[0]')
cli -rpcwallet=padre send "{\"$A\":0.5}" >/dev/null
mina 1
echo "3) El padre envía 0,5 a la hucha. Saldo de la cartera herencia: $(cli -rpcwallet=herencia getbalances | jq .mine.trusted)"

# Ana: importa la hucha con su clave privada
cli -named createwallet wallet_name=herencia_ana blank=true >/dev/null
DA="wsh(or_d(pk($PADRE/0/*),and_v(v:pk($ANA_PRIV/0/*),after($H))))"
cli -rpcwallet=herencia_ana importdescriptors "[{\"desc\":\"$DA#$(cli getdescriptorinfo "$DA" | jq -r .checksum)\",\"timestamp\":0}]" >/dev/null
echo "4) Ana ve su hucha: $(cli -rpcwallet=herencia_ana getbalances | jq .mine.trusted) BTC"

DEST=$(cli -rpcwallet=llave_ana getnewaddress)
cli -rpcwallet=herencia_ana -named sendall recipients="[\"$DEST\"]" fee_rate=5 locktime=$H add_to_wallet=false | jq -r .hex > "$DIR/tx.hex"
echo "5) Bloque $(cli getblockcount): ¿la red acepta el cobro? $(cli testmempoolaccept "[\"$(cat "$DIR/tx.hex")\"]" | jq -c '.[0] | {allowed, "reject-reason"}')"

mina 20
echo "6) Bloque $(cli getblockcount): ¿y ahora? $(cli testmempoolaccept "[\"$(cat "$DIR/tx.hex")\"]" | jq -c '.[0] | {allowed}')"
cli sendrawtransaction "$(cat "$DIR/tx.hex")" >/dev/null
mina 1
echo "7) Herencia cobrada. Saldo de Ana: $(cli -rpcwallet=llave_ana getbalances | jq .mine.trusted) BTC"

cli stop >/dev/null
echo "Ensayo terminado. Para borrarlo: rm -rf \"$DIR\""
