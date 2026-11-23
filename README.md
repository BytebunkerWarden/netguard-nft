# netguard-nft


salli useampia palvelimia:
Ajoin scriptin. miten sallin niihin pääsyn?

Suoraan netguard-skriptin render_rules-funktioon tai suoraan nftables-tauluun (inet killswitch) lisäämällä, koska nykyinen netguard tukee oletuksena vain yhtä kovakoodattua VPN_IP- ja VPN_PORT-paria (142.4.216.196:25000/UDP).   
install-netguard.sh
+ 2

Siistein ja pysyvin tapa on tallentaa poimitut palvelimet tiedostoon (esim. /etc/netguard/vpn-endpoints) ja muokata /usr/local/sbin/netguard-skriptiä lukemaan ne siitä sekä restricted- että vpn-tilassa.   
install-netguard.sh
+ 1

1. Luo tiedosto VPN-endpointeille
Tallenna poimimasi proto ip port -rivit (varmista, että kohteet ovat IPv4-osoitteita, eivät domain-nimiä) tiedostoon /etc/netguard/vpn-endpoints, esimerkiksi muodossa:

Plaintext
udp 142.4.216.196 25000
udp 185.x.x.x 1194
tcp 198.x.x.x 443
(Jos awk-tulosteessasi oli domain-nimiä, ratkaise ne ensin IPv4-osoitteiksi getent ahostsv4 <domain>-komennolla ennen tiedostoon tallentamista.)

2. Muokkaa /usr/local/sbin/netguard-tiedostoa
Etsi /usr/local/sbin/netguard-tiedostosta render_rules()-funktion kohta, jossa alkuperäinen VPN-sääntö luodaan:   
install-netguard.sh
+ 1

Bash
  if [[ "$mode" == restricted || "$mode" == vpn ]]; then
    printf '        oifname "%s" ip daddr %s udp dport %s accept\n' "$PHYSICAL_IF" "$VPN_IP" "$VPN_PORT"
  fi
Korvaa tuo lohko niin, että se lukee /etc/netguard/vpn-endpoints-tiedoston (ja säilyttää oletus-VPN:n varalla, jos tiedostoa ei ole):

Bash
  if [[ "$mode" == restricted || "$mode" == vpn ]]; then
    if [[ -r /etc/netguard/vpn-endpoints ]]; then
      while read -r vproto vip vport _; do
        [[ -z "$vproto" || "$vproto" == \#* ]] && continue
        printf '        oifname "%s" ip daddr %s %s dport %s accept\n' "$PHYSICAL_IF" "$vip" "$vproto" "$vport"
      done < /etc/netguard/vpn-endpoints
    else
      printf '        oifname "%s" ip daddr %s udp dport %s accept\n' "$PHYSICAL_IF" "$VPN_IP" "$VPN_PORT"
    fi
  fi
(Huom: muista päivittää sama kohta myös install-netguard.sh- ja netguard-controller.sh-tiedostoihin, jos ajat asennusskriptin joskus uudelleen.)   
install-netguard.sh
+ 2

3. Validoi, ota käyttöön ja päivitä käynnistysasetus
Aja seuraavat komennot säännöstön tarkistamiseksi ja aktivoimiseksi:

Bash
# 1. Tarkista skriptin syntaksi ja nftables-säännöt
bash -n /usr/local/sbin/netguard
sudo netguard render restricted | nft -c -f -

# 2. Päivitä myös boottikonfiguraatio (/etc/nftables.conf), jotta säännöt säilyvät uudelleenkäynnistyksessä
sudo netguard lan "$(sudo netguard lan status | awk '/LAN profile:/ {print $3}')"

# 3. Ota tila käyttöön (restricted tai vpn)
sudo netguard restricted
(Vaihe 2 käyttää netguard lan -komentoa, koska se kirjoittaa päivitetyn restricted-säännöstön suoraan /etc/nftables.conf-tiedostoon.)   
install-netguard.sh
+ 1

4. Tarkista tulos
Aja sudo nft list table inet killswitch. output-ketjussa pitäisi nyt näkyä oma oifname "eth0" ip daddr ... accept -rivi jokaiselle tiedostoon lisäämällesi VPN-palvelimelle.   
NETGUARD-GUIDE.md
+ 2

Jos haluat vain nopean kertaluontoisen testin ilman tiedostojen muokkaamista (katoaa tilan vaihdossa tai rebootissa), voit lisätä säännön lennosta komennolla:

Bash
sudo nft insert rule inet killswitch output oifname "eth0" ip daddr <VPN_IP> udp dport <PORTTI> accept
$ sudo openvpn --config /mnt/Shared/openvpn/vpnbook-uk68-tcp80.ovpn

2026-11-23 22:51:06 DEPRECATED OPTION: --persist-key option ignored. Keys are now always persisted across restarts.

2026-11-23 22:51:06 DEPRECATED OPTION: --fast-io option ignored.

2026-11-23 22:51:06 OpenVPN 2.7.8 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [PKCS11] [MH/PKTINFO] [AEAD] [DCO]

2026-11-23 22:51:06 library versions: OpenSSL 3.6.5 29 Sep 2026, LZO 2.10

2026-11-23 22:51:06 DCO version: 7.2.15+kali-amd64 #1 SMP PREEMPT_DYNAMIC Kali 7.2.15-1kali1 (2026-11-03)

Enter Auth Username: vpnbook

Enter Auth Password: •••••••

2026-11-23 22:51:16 WARNING: No server certificate verification method has been enabled. See http://openvpn.net/howto.html#mitm for more info.

2026-11-23 22:51:16 TCP/UDP: Preserving recently used remote address: [AF_INET]145.239.255.68:80

2026-11-23 22:51:16 Socket Buffers: R=[131072->131072] S=[16384->16384]

2026-11-23 22:51:16 Attempting to establish TCP connection with [AF_INET]145.239.255.68:80

^[[A^[[B^C2026-11-23 22:51:26 SIGINT[hard,init_instance] received, process exiting

Attempting to establish TCP connection with [AF_INET]145.239.255.68:80 jäi roikkumaan, kunnes keskeytit sen (Ctrl+C). Syy on suoraan Netguard-palomuurissa: kohde on 145.239.255.68 ja portti 80 (tcp), mutta Netguard sallii eth0-liitännän kautta oletuksena vain osoitteen 142.4.216.196 UDP-porttiin 25000.   
install-netguard.sh
+ 1

Nopein ratkaisu tähän yhteyteen (kertaluontoinen testi)
Jos haluat heti testata, meneekö vpnbook-uk68-tcp80.ovpn läpi, lisää 145.239.255.68 TCP-portti 80 killswitch-tauluun:

Bash
sudo nft insert rule inet killswitch output oifname "eth0" ip daddr 145.239.255.68 tcp dport 80 accept
Varmistus: Aja sudo nft list table inet killswitch ja varmista, että output-ketjussa näkyy oifname "eth0" ip daddr 145.239.255.68 tcp dport 80 accept. Käynnistä OpenVPN uudelleen – sen pitäisi nyt siirtyä TCP-yhteyden muodostamisesta eteenpäin (tai antaa mahdollinen OpenVPN-tason virhe, jos palvelin tai tunnistetiedot eivät täsmää).   
NETGUARD-GUIDE.md

Pysyvä lisäys (restricted- ja vpn-tiloihin)
Jos haluat, että 145.239.255.68:80/tcp (ja muut .ovpn-kohteet) pysyvät sallittuina tilanvaihdoissa ja uudelleenkäynnistyksissä:

Lisää rivi /etc/netguard/vpn-endpoints-tiedostoon:

Plaintext
tcp 145.239.255.68 80
Varmistus: Aja grep -F "145.239.255.68" /etc/netguard/vpn-endpoints ja tarkista, että rivi näkyy muodossa tcp 145.239.255.68 80.

Varmista, että /usr/local/sbin/netguard-tiedoston render_rules-funktio lukee /etc/netguard/vpn-endpoints-tiedostoa ja käytä siinä muuttujaa $vproto (%s dport %s accept), ei kovakoodattua udp-sanaa.
Varmistus: Aja bash -n /usr/local/sbin/netguard ja sudo netguard render restricted | nft -c -f - – kumpikaan ei saa antaa virheitä.   
install-netguard.sh
+ 1

Päivitä käynnistyskonfiguraatio ja ota tila käyttöön:

Bash
sudo netguard lan "$(sudo netguard lan status | awk '/LAN profile:/ {print $3}')"
sudo netguard restricted
Varmistus: Aja sudo nft list table inet killswitch ja tarkista, että sääntö oifname "eth0" ip daddr 145.239.255.68 tcp dport 80 accept on mukana.   
install-netguard.sh
+ 2

Huomaa myös, että lokissa näkyi DEPRECATED OPTION: --fast-io option ignored – se on vain OpenVPN 2.7:n varoitus (--fast-io ei vaikuta TCP-soketteihin), eikä estä yhteyttä.
