#!/bin/bash

openssl s_client -showcerts -verifyCAfile ../mysetup/int.crt -servername crd.d8k.dev -connect 127.0.0.1:30443 </dev/null  | grep After
