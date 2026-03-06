# Techno Serverless OMS — Paket Juri

## Struktur
```
techno-juri/
├── deploy-juri.sh              ← Script deploy otomatis (7 CFN stacks)
├── amplify.yml                 ← Konfigurasi build AWS Amplify
├── cloudformation/             ← 7 CloudFormation templates
│   ├── 01-networking.yaml      VPC, Subnets, Security Groups, VPC Endpoints
│   ├── 02-storage.yaml         S3, Secrets Manager, Parameter Store
│   ├── 03-database.yaml        RDS PostgreSQL 15
│   ├── 04-compute.yaml         Lambda Layer + 7 Functions + SNS + DynamoDB
│   ├── 05-orchestration.yaml   Step Functions + EventBridge
│   ├── 06-apigateway.yaml      REST API + 9 endpoints + API Key
│   └── 07-cicd.yaml            CodeDeploy + CloudWatch Alarms + Dashboard
├── lambda/                     ← Source code 7 Lambda functions
├── frontend/
│   └── index.html              ← Dashboard frontend (deploy via Amplify)
├── codedeploy/
│   └── appspec.yml             ← AppSpec CodeDeploy Blue/Green
├── step_functions/
│   └── order-workflow.json     ← ASL Step Functions (referensi)
└── .github/workflows/
    └── deploy.yml              ← GitHub Actions CI/CD (5 jobs)
```

---

# 

## STEP 1 — Deploy Infrastruktur (Satu Script)

```bash
# Set AWS credentials dari Learner Lab
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...

chmod +x deploy-juri.sh
./deploy-juri.sh juritest 01 email@example.com
#                ^nama    ^suffix ^email notifikasi
```

**Estimasi: ~25 menit** (mayoritas menunggu RDS)

Setelah selesai, script mencetak file `deploy-output.txt` berisi semua output:
- API Endpoint & API Key
- SNS Topic ARN, Step Functions ARN, RDS Endpoint
- Link CloudWatch Dashboard

---

## STEP 2 — Test API

```bash
API_URL=$(grep "API Endpoint" deploy-output.txt | awk '{print $NF}')
API_KEY=$(grep "API Key " deploy-output.txt | awk '{print $NF}')

# Health check
curl -s -H "x-api-key: $API_KEY" "$API_URL/health" | python3 -m json.tool

# List orders (sample data sudah diinsert)
curl -s -H "x-api-key: $API_KEY" "$API_URL/orders" | python3 -m json.tool

# Buat order baru
curl -s -X POST "$API_URL/orders" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"customerId":"CUST001","items":[{"productId":"PROD001","quantity":2}],"totalAmount":50000}' \
  | python3 -m json.tool
```

---

## STEP 3 — Setup AWS Amplify (Frontend)

1. Buka **AWS Console → Amplify → New App → Host Web App**
2. Pilih **GitHub** → connect repo → pilih branch `master`
3. Amplify auto-detect `amplify.yml`
4. Tambah **Environment Variables**:

| Key | Value |
|-----|-------|
| `API_ENDPOINT` | (dari deploy-output.txt) |
| `API_KEY` | (dari deploy-output.txt) |
| `AWS_REGION` | `us-east-1` |

5. Klik **Save and Deploy** → tunggu build selesai
6. Buka URL Amplify → dashboard frontend siap

---

## STEP 4 — Setup GitHub Actions CI/CD

### Secrets yang diperlukan di GitHub repo
(Settings → Secrets and variables → Actions → New repository secret)

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | dari Learner Lab |
| `AWS_SECRET_ACCESS_KEY` | dari Learner Lab |
| `AWS_SESSION_TOKEN` | dari Learner Lab |
| `SNS_TOPIC_ARN` | dari deploy-output.txt |
| `S3_DEPLOYMENT_BUCKET` | nama bucket logs (dari deploy-output.txt) |
| `AMPLIFY_APP_ID` | dari console Amplify (format: dXXXXXXXXX) |

### Trigger CI/CD
```bash
git add .
git commit -m "trigger ci/cd test"
git push origin master
```

Pipeline 5 jobs akan berjalan:
1. **Track & Notify** — deteksi fork, log pipeline start
2. **Test & Lint** — validasi syntax Python, JSON, HTML
3. **Deploy Lambda** — update code + publish version + CodeDeploy Blue/Green
4. **Deploy Frontend** — trigger Amplify build
5. **Notify** — kirim laporan via SNS email

---

## STEP 5 — Verifikasi CodeDeploy

Setelah push ke master dan pipeline selesai:
- **AWS Console → CodeDeploy → Applications → techno-codedeploy-app**
- Tab **Deployments** akan menampilkan history deployment Blue/Green
- Strategi: **Canary10Percent5Minutes** (10% traffic dulu 5 menit, lalu 100%)

---

## Troubleshooting

| Error | Solusi |
|-------|--------|
| S3 bucket AlreadyExists | Ganti `BucketSuffix` di parameter script (02, 03, ...) |
| RDS CREATE_FAILED | Cek `describe-stack-events`, biasanya `gp2` vs `gp3` atau engine version |
| API Gateway CW Logs error | Script sudah auto-set via `aws apigateway update-account` |
| Lambda AccessDenied S3 | Pastikan `LayerS3Bucket` dan `LambdaS3Bucket` benar |
| CodeDeploy no deployments | Normal — muncul setelah push ke master |
