### Assumption

1. This test based on KIND (Kubernetes in Docker)
2. Port 443 / Node 1 published to TCP/30443 on host
3. Docker Desktop for macOS
4. HashiCorp Vault is already installed in a namespace called "vault" and unsealed in Kubernetes Cluster.
5. certbot is already installed.

### Step by Step
1. Generate and Export Non-expired ServiceAccount Token for Hashicorp Vault's Kubernetes Authentication Method 

```
mkdir mysetup
cd mysetup
cat > sa.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: d8k
EOF

cat > sa-rolebinding.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tkreview-rolebinding
  namespace: default
subjects:
- kind: ServiceAccount
  name: d8k
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
EOF

cat > secret.yaml <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: d8k-token
  annotations:
    kubernetes.io/service-account.name: d8k
EOF

kubectl apply -f sa.yaml -f sa-rolebinding.yaml -f secret.yaml
kubectl get secret d8k-token -o json | jq -r ".data.token" | base64 -d | tr -d '\n'| tr -d '\r' > mytoken

```

2. Enable PKI Secrets Engine and Generate Root Certificate Authority
```
vault login $TOKEN
CA_PATH=pki_ca

vault secrets enable -path=${CA_PATH} pki

vault secrets tune -max-lease-ttl=87600h ${CA_PATH}

vault write -field=certificate ${CA_PATH}/root/generate/internal \
   common_name="d8k CA" \
   max_path_length=5 \
   ou="d8k CyberSecurity" \
   organization="d8k" \
   country="TH" \
   key_bits=4096 \
   issuer_name="d8k-ca" \
   ttl=87600h > ca.crt

vault write pki_ca/config/cluster \
   path=https://localhost:30200/v1/pki_ca \
   aia_path=http://localhost:30200/v1/pki_ca



vault write pki_ca/config/urls \
     issuing_certificates={{cluster_aia_path}}/issuer/{{issuer_id}}/der \
     crl_distribution_points={{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der \
     ocsp_servers={{cluster_path}}/ocsp \
     enable_templating=true

vault write ${CA_PATH}/roles/ca_issuer \
     allow_any_name=true \
     ext_key_usage="serverAuth, clientAuth" \
     ou="Development Dept" organization="d8k" country="TH" \
     key_usage="DigitalSignature, KeyEncipherment" \
     no_store=false \
     ttl=1h \
     max_ttl=1h
```

3. Enable PKI Secrets Engine and Generate Intermediat Certificate Authority

```
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

vault write -format=json pki_int/intermediate/generate/internal \
     common_name="d8k Intermediate Authority"   | jq -r '.data.csr' > int.csr

vault write -format=json ${CA_PATH}/root/sign-intermediate  \
     csr=@int.csr \
     format=pem_bundle \
     ttl="43800h"  | jq -r '.data.certificate' > int.crt

vault write pki_int/intermediate/set-signed certificate=@int.crt

vault write pki_int/config/cluster \
    path=https://localhost:30200/v1/pki_int \
    aia_path=https://localhost:30200/v1/pki_int

vault write pki_int/roles/d8kint \
       ext_key_usage="serverAuth, clientAuth"  \
       issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
       allow_any_name=true  \
       max_ttl="1h" ttl="1h"

vault write pki_int/roles/d8ktest \
       ext_key_usage="serverAuth, clientAuth"  \
       allow_any_name=true  \
       max_ttl="1h" ttl="1h"

vault write pki_int/config/urls issuing_certificates={{cluster_aia_path}}/issuer/{{issuer_id}}/der  crl_distribution_points={{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der  ocsp_servers={{cluster_path}}/ocsp   enable_templating=true
```

4. Create Role to allow  Intermediat CA
```
vault policy write pki - <<EOF
path "pki_int*"                        { capabilities = ["read", "list"] }
path "pki_int/sign/d8kint"    { capabilities = ["create", "update"] }
path "pki_int/issue/d8kint"   { capabilities = ["create"] }
EOF
```
5. Enable and Configuration Kubernetes Autheticaiton Method
```
vault auth enable -path=k8s_certmanager  kubernetes

kubectl get secret d8k-token -o json | jq -r '.data["ca.crt"]' | base64 -d  > k8sca.crt
KUBERNETES_PORT_443_TCP_ADDR=$(kubectl exec -it -n vault vault-0 -- sh -c 'echo $KUBERNETES_PORT_443_TCP_ADDR'| tr -d '\n'| tr -d '\r')


vault write auth/k8s_certmanager/config \
token_reviewer_jwt="$(cat mytoken)" \
kubernetes_host=https://${KUBERNETES_PORT_443_TCP_ADDR}:443 \
kubernetes_ca_cert=@k8sca.crt


vault write auth/k8s_certmanager/role/issuer \
   bound_service_account_names=issuer \
   bound_service_account_namespaces=default \
   policies=pki \
   ttl=1h
```

6. Install cert-manager
```
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.12.3/cert-manager.crds.yaml
kubectl create namespace cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager --namespace cert-manager --version v1.12.3 jetstack/cert-manager
kubectl get pods --namespace cert-manager
```

7. Create cert-manager's issuer
```
kubectl create secret generic tls-ca-cert --from-file=ca.crt=../pki/ca.crt
kubectl create serviceaccount issuer
cat > issuer-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: issuer-token
  annotations:
    kubernetes.io/service-account.name: issuer
type: kubernetes.io/service-account-token
EOF
kubectl apply -f issuer-secret.yaml


cat > vault-issuer.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: default
spec:
  vault:
    caBundleSecretRef:
        key: ca.crt
        name: tls-ca-cert
    server: https://vault.vault.svc.cluster.local:8200
    path: pki_int/sign/d8kint
    auth:
      kubernetes:
        mountPath: /v1/auth/k8s_certmanager
        role: issuer
        secretRef:
          name: issuer-token
          key: token
EOF
kubectl apply --filename vault-issuer.yaml
```

8. Make sure that issuer works.
```
cat > d8k-dev-cert.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-d8k-dev
  namespace: default
spec:
  secretName: test-d8k-dev-tls
  renewBefore: 55m
  duration: 1h
  issuerRef:
    name: vault-issuer
  commonName: test.d8k.dev
  dnsNames:
  - test.d8k.dev
EOF
kubectl apply --filename d8k-dev-cert.yaml
```

9. Verify cert-manager
```
kubectl describe certificate.cert-manager test-d8k-dev
```
 10. Install NGINX Ingress Controller

```
kubectl create secret tls tls-server --cert ../pki/server1.crt --key ../pki/server1.key
helm install mynginx-ingress oci://ghcr.io/nginxinc/charts/nginx-ingress --version 1.0.1 -f ../config/nginx-value.yaml
kubectl get pods -w
```

11. Install Sample App

```
kubectl apply -f ../app/app.yaml
```

12. 

```
../tools/create-ca-mtls-yaml

cat > virtualserver.yaml <<EOF
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
    name: cafe
spec:
    policies:
      - name: enable-mtls
    host: crd.d8k.dev
    tls:
      secret: ingress-crd
      cert-manager:
        issuer: "vault-issuer"
        common-name: crd.d8k.dev
    upstreams:
      - name: tea
        service: tea-svc
        port: 80
      - name: coffee
        service: coffee-svc
        port: 80
    routes:
      - path: /tea
        action:
          pass: tea
      - path: /coffee
        action:
          pass: coffee
EOF
cat > policy.yaml <<EOF
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: enable-mtls
spec:
 ingressMTLS:
  clientCertSecret: ca-mtls-secret
  verifyClient: "on"
  verifyDepth: 1
EOF
kubectl apply -f virtualserver.yaml -f ca-mtls.yaml -f policy.yaml
```


13. Verify Result
 
```
curl -k --resolve crd.d8k.dev:30443:127.0.0.1  https://crd.d8k.dev:30443/tea
<html>
<head><title>400 No required SSL certificate was sent</title></head>
<body>
<center><h1>400 Bad Request</h1></center>
<center>No required SSL certificate was sent</center>
<hr><center>nginx/1.25.2</center>
</body>
</html>
```

14. Enable ACME
```
vault secrets tune  -passthrough-request-headers=If-Modified-Since  -allowed-response-headers=Last-Modified  -allowed-response-headers=Location -allowed-response-headers=Replay-Nonce -allowed-response-headers=Link pki_int
vault write pki_int/config/acme enabled=true eab_policy=always-required allow_role_ext_key_usage=true
```


15. Request Key Pair from ACME Server
```
vault write -force pki_int/roles/d8kint/acme/new-eab > eab.txt
cat eab.txt |grep id| awk '{print "export EAB_ID="$2}' > .certbotrc
cat eab.txt |grep key | head -n 1| awk '{print "export EAB_KEY="$2}' >> .certbotrc
source .certbotrc


cat ../pki/ca.crt > my.pem
cat /opt/homebrew/etc/ca-certificates/cert.pem >> my.pem

export REQUESTS_CA_BUNDLE=./my.pem


# Obtain certificates using a DNS TXT record in DigitalOcean
# Create .digitaloceanrc
# dns_digitalocean_token = <DigitalOcean API KEY>

certbot certonly --config-dir=. --work-dir=. --logs-dir=.  --server https://localhost:30200/v1/pki_int/roles/d8kint/acme/directory --email damrongs@gmail.com -d drs.d8k.dev --eab-kid=$EAB_ID --eab-hmac-key=$EAB_KEY --no-eff-email --dns-digitalocean --dns-digitalocean-credentials ./.digitaloceanrc --force-renew --key-type rsa
```

13. Verify Result
 
```
curl -k --resolve crd.d8k.dev:30443:127.0.0.1  --cacert ./int.crt --key ./live/drs.d8k.dev/privkey.pem --cert ./live/drs.d8k.dev/fullchain.pem   https://crd.d8k.dev:30443/tea
Server Info: 10.244.2.10:8080 - tea-65cdf5884d-4f64s <> URL: /tea <> Src: 10.244.2.9
```

