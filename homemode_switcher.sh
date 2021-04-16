#!/bin/bash

########## Mandatory configuration
SYNO_USER="user";
SYNO_PASS="password";
SYNO_URL="192.168.1.111:port";
########## 2FA configuration (optional)
SYNO_SECRET_KEY="";
PYTHON_VOLUME="volume1";
######################################
######################################
######################################
######################################
######################################
######################################

ARGUMENTS=$@
MACS=$(echo $ARGUMENTS | tr '[:lower:]' '[:upper:]');

ID="$RANDOM";
COOKIESFILE="$0_cookies_$ID";
AMIHOME="$0_AMIHOME";


function totp_calculator() {
	#test_python=$(python3 --version|awk '{print $1}')
	test_python="/$PYTHON_VOLUME/@appstore/py3k/usr/local/bin/python3"
	test_pip="/$PYTHON_VOLUME/@appstore/py3k/usr/local/bin/pip"
	#test_pyotp=$(python3 /$PYTHON_VOLUME/@appstore/py3k/usr/local/bin/pip list|grep pyotp|awk '{ if ($1=="pyotp") print $1 }')
	test_pyotp="/$PYTHON_VOLUME/@appstore/py3k/usr/local/lib/python3.8/site-packages/pyotp"
	#if [ "$test_python" == "Python" ]; then
	if [ -f "$test_python" ]; then
		if [ -f "$test_pip" ]; then
			#if [ "$test_pyotp" == "pyotp" ]; then	
			if [ -d "$test_pyotp" ]; then
				SYNO_OTP="$(python3 - <<END
import pyotp
totp = pyotp.TOTP("$SYNO_SECRET_KEY")
print(totp.now())
END
)"			
			else
				echo "Pyotp module is not installed"
				echo "Try with \"python3 /$PYTHON_VOLUME/@appstore/py3k/usr/local/bin/pip install pyotp\""
				exit 1;
			fi
		else
			echo "Pip is not installed"
			echo "Try with \"wget https://bootstrap.pypa.io/get-pip.py -O /tmp/get-pip.py\" followed by \"sudo python3 /tmp/get-pip.py\""
			exit 1;
		fi
	else
		echo "Python3 is not installed"
		echo "Install it from the Package Center"
		exit 1;
	fi
}


function switchHomemode()
{
	if [ -z "$SYNO_SECRET_KEY" ]; then
		echo -e "\nNo 2FA secret key detected"
		login_output=$(wget -q --keep-session-cookies --save-cookies $COOKIESFILE -O- "http://${SYNO_URL}//webapi/auth.cgi?api=SYNO.API.Auth&method=Login&version=3&account=${SYNO_USER}&passwd=${SYNO_PASS}&session=SurveillanceStation"|awk -F'[][{}]' '{ print $4 }'|awk -F':' '{ print $2 }');
	else
		echo -e "\n2FA secret key detected, I'm using it"
		totp_calculator
		login_output=$(wget -q --keep-session-cookies --save-cookies $COOKIESFILE -O- "http://${SYNO_URL}//webapi/auth.cgi?api=SYNO.API.Auth&method=Login&version=3&account=${SYNO_USER}&passwd=${SYNO_PASS}&otp_code=${SYNO_OTP}&session=SurveillanceStation"|awk -F'[][{}]' '{ print $4 }'|awk -F':' '{ print $2 }');
	fi
	if [ "$login_output" == "true" ]; then 
		echo "Login to Synology successfull";
		homestate_prev_syno=$(wget -q --load-cookies $COOKIESFILE -O- "http://${SYNO_URL}//webapi/entry.cgi?api=SYNO.SurveillanceStation.HomeMode&version=1&method=GetInfo&need_mobiles=true"|awk -F',' '{ print $124 }'|awk -F':' '{ print $2 }');
		if [ "$homestate" == "true" ] && [ "$homestate_prev_syno" != "$homestate" ]; then
			echo "Synology is NOT in Homemode but you're at home... Let's fix it"
			switch_output=$(wget -q --load-cookies $COOKIESFILE -O- "http://${SYNO_URL}//webapi/entry.cgi?api=SYNO.SurveillanceStation.HomeMode&version=1&method=Switch&on=true");
			if [ "$switch_output" = '{"success":true}' ]; then  
				echo "Homemode correctly activated"; 
				echo $homestate>$AMIHOME
			else
				echo "Something went wrong during the activation of Homemode"
				exit 1;
			fi	
		elif [ "$homestate" == "false" ] && [ "$homestate_prev_syno != $homestate" ]; then
			echo "Synology is in Homemode but you're NOT at home... Let's fix it"
			switch_output=$(wget -q --load-cookies $COOKIESFILE -O- "http://${SYNO_URL}//webapi/entry.cgi?api=SYNO.SurveillanceStation.HomeMode&version=1&method=Switch&on=false");
			if [ "$switch_output" = '{"success":true}' ]; then  
				echo "Homemode correctly deactivated"; 
				echo $homestate>$AMIHOME
			else
				echo "Something went wrong during the deactivation of Homemode"
				exit 1;
			fi	
		elif [ "$homestate" == "false" ] && [ "$homestate_prev_syno == $homestate" ]; then
			echo "Synology is NOT in Homemode and you're NOT at home...Fixing only the AMIHOME file";
			echo $homestate>$AMIHOME
		elif [ "$homestate" == "true" ] && [ "$homestate_prev_syno == $homestate" ]; then
			echo "Synology is in Homemode and you're at home...Fixing only the AMIHOME file";
			echo $homestate>$AMIHOME
		fi
		logout_output=$(wget -q --load-cookies $COOKIESFILE -O- "http://${SYNO_URL}/webapi/auth.cgi?api=SYNO.API.Auth&method=Logout&version=1");
		if [ "$logout_output" = '{"success":true}' ]; then echo "Logout to Synology successfull"; fi
	else
		echo "Login to Synology went wrong";
		exit 1;
	fi
	rm $COOKIESFILE;
}


function macs_check_v1()
{	
	matching_macs=0
	interface=$(route|grep default|awk '{print $8}')
	ip_pool=$(echo $SYNO_URL|awk -F"." 'BEGIN{OFS="."} {print $1, $2, $3".0/24"}')
	echo "Scanning hosts in the same network of the Synology NAS..."
	nmap_scan=$(nmap -sn --disable-arp-ping $ip_pool|awk '/MAC/{print $3}')
	echo -e "\nHosts found in your network:"
	for host in $nmap_scan; do
		echo -e "\n$host"
		for authorized_mac in $MACS
		do
			if [ "$host" == "$authorized_mac" ]; then
				let "matching_macs+=1"
				echo "This MAC address matches with one of the authorized MAC addresses!"
			fi
		done
	done
}


function macs_check_v2()
{	
	matching_macs=0
	interface=$(route|grep default|awk '{print $8}')
	ip_pool=$(echo $SYNO_URL|awk -F"." 'BEGIN{OFS="."} {print $1, $2, $3".0/24"}')
	echo "Scanning hosts in the same network of the Synology NAS..."
	nmap_scan=$(nmap --traceroute --disable-arp-ping $ip_pool|awk '/MAC/{print $3}')
	echo -e "\nHosts found in your network:"
	for host in $nmap_scan; do
		echo -e "\n$host"
		for authorized_mac in $MACS
		do
			if [ "$host" == "$authorized_mac" ]; then
				let "matching_macs+=1"
				echo "This MAC address matches with one of the authorized MAC addresses!"
			fi
		done
	done
}


#Check for the list of MAC addresses authorized to activate Homemode passed as script arguments

if [ $# -eq 0 ]; then
	echo "MAC address or addresses missing"
	exit 1;
fi


#Check for previous state stored in a file for avoiding continuous SynoAPI calls

if [ -f $AMIHOME ]; then
	homestate_prev_file=$(<$AMIHOME)
else
	echo "unknown">$AMIHOME
	homestate_prev_file=$(<$AMIHOME)
fi
echo "[Previous State] Am I home? $homestate_prev_file" 
echo "MAC addresses authorized to enable the Homemode: $MACS"


#Check for currently active MAC addresses and comparison with the provided authorized MACs

macs_check_v1

echo -e "\nTotal matches: $matching_macs"

if [ "$matching_macs" -eq "0" ]; then
	homestate="false"
elif [ "$matching_macs" -gt "0" ]; then
	homestate="true"
fi
echo "[Current State] Am I home? $homestate"

if [ $homestate_prev_file != $homestate ]; then
	echo "Switching Home Mode according to the [Current State]..."
	switchHomemode
else
	echo "No changes made"
fi

exit 0;
