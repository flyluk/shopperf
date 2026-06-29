#!/bin/bash
set -euo pipefail
BASE=/home/flyluk/development/shop-demo

cat > "$BASE/backend/app/config.py" <<'EOF'
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql://shopuser:shoppass@postgres:5432/shopdb"
    jwt_secret: str = "change-me-in-production"
    jwt_expire_minutes: int = 60
    jwt_algorithm: str = "HS256"

    db_pool_size: int = Field(default=5, alias="DB_POOL_SIZE")
    db_max_overflow: int = Field(default=8, alias="DB_MAX_OVERFLOW")
    db_pool_timeout: int = Field(default=5, alias="DB_POOL_TIMEOUT")
    db_pool_recycle: int = Field(default=1800, alias="DB_POOL_RECYCLE")

    uvicorn_workers: int = Field(default=4, alias="UVICORN_WORKERS")


settings = Settings()
EOF

cat > "$BASE/backend/app/database.py" <<'EOF'
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import settings

engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=settings.db_pool_size,
    max_overflow=settings.db_max_overflow,
    pool_timeout=settings.db_pool_timeout,
    pool_recycle=settings.db_pool_recycle,
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF

python3 <<'PY'
from pathlib import Path
p = Path("/home/flyluk/development/shop-demo/backend/app/auth.py")
text = p.read_text()
if "get_current_user_id" not in text:
    insert = '''

def get_current_user_id(
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> int:
    """JWT-only auth — skips a DB round-trip on hot paths like cart."""
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(
            credentials.credentials,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
        user_id = payload.get("sub")
        if user_id is None:
            raise credentials_exception
        return int(user_id)
    except (JWTError, ValueError) as exc:
        raise credentials_exception from exc
'''
    p.write_text(text.rstrip() + insert + "\n")
PY

cat > "$BASE/backend/app/routers/cart.py" <<'EOF'
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session, joinedload

from app.auth import get_current_user, get_current_user_id
from app.database import get_db
from app.models import CartItem, Product, User
from app.schemas import CartItemCreate, CartItemResponse, CartItemUpdate, CartResponse

router = APIRouter(prefix="/api/cart", tags=["cart"])


def _cart_total(items: list[CartItem]) -> float:
    return sum(float(item.product.price) * item.quantity for item in items)


@router.get("", response_model=CartResponse)
def get_cart(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    items = (
        db.query(CartItem)
        .options(joinedload(CartItem.product))
        .filter(CartItem.user_id == current_user.id)
        .all()
    )
    return CartResponse(items=items, total=_cart_total(items))


@router.post("/items", response_model=CartItemResponse, status_code=status.HTTP_201_CREATED)
def add_cart_item(
    payload: CartItemCreate,
    user_id: int = Depends(get_current_user_id),
    db: Session = Depends(get_db),
):
    product = db.get(Product, payload.product_id)
    if not product:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")

    if product.stock < payload.quantity:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Insufficient stock")

    existing = (
        db.query(CartItem)
        .options(joinedload(CartItem.product))
        .filter(CartItem.user_id == user_id, CartItem.product_id == payload.product_id)
        .first()
    )
    if existing:
        if product.stock < existing.quantity + payload.quantity:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Insufficient stock")
        existing.quantity += payload.quantity
        product.stock -= payload.quantity
        db.commit()
        db.refresh(existing)
        return existing

    product.stock -= payload.quantity
    item = CartItem(user_id=user_id, product_id=payload.product_id, quantity=payload.quantity)
    item.product = product
    db.add(item)
    db.commit()
    db.refresh(item)
    return item


@router.patch("/items/{item_id}", response_model=CartItemResponse)
def update_cart_item(
    item_id: int,
    payload: CartItemUpdate,
    user_id: int = Depends(get_current_user_id),
    db: Session = Depends(get_db),
):
    item = (
        db.query(CartItem)
        .options(joinedload(CartItem.product))
        .filter(CartItem.id == item_id, CartItem.user_id == user_id)
        .first()
    )
    if not item:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Cart item not found")

    delta = payload.quantity - item.quantity
    if delta > 0 and item.product.stock < delta:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Insufficient stock")

    item.product.stock -= delta
    item.quantity = payload.quantity
    db.commit()
    db.refresh(item)
    return item


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_cart_item(
    item_id: int,
    user_id: int = Depends(get_current_user_id),
    db: Session = Depends(get_db),
):
    item = (
        db.query(CartItem)
        .options(joinedload(CartItem.product))
        .filter(CartItem.id == item_id, CartItem.user_id == user_id)
        .first()
    )
    if not item:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Cart item not found")
    item.product.stock += item.quantity
    db.delete(item)
    db.commit()
EOF

cat > "$BASE/backend/start.sh" <<'EOF'
#!/bin/sh
set -e
WORKERS="${UVICORN_WORKERS:-4}"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers "${WORKERS}"
EOF
chmod +x "$BASE/backend/start.sh"

cat > "$BASE/backend/Dockerfile" <<'EOF'
FROM python:3.12-slim AS base

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY start.sh ./start.sh

USER appuser

EXPOSE 8000

CMD ["./start.sh"]
EOF

cat > "$BASE/frontend/nginx.conf" <<'EOF'
upstream api_backend {
    server api:8000;
    keepalive 64;
}

server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /api/ {
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        proxy_pass http://api_backend/api/;
    }

    location /health {
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
        proxy_pass http://api_backend/health;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

cat > "$BASE/k8s/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-demo-config
  namespace: shop-demo
data:
  JWT_EXPIRE_MINUTES: "60"
  UVICORN_WORKERS: "4"
  DB_POOL_SIZE: "5"
  DB_MAX_OVERFLOW: "8"
  DB_POOL_TIMEOUT: "5"
  DB_POOL_RECYCLE: "1800"
EOF

cat > "$BASE/k8s/api-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop-demo
  labels:
    app: api
spec:
  replicas: 4
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: shop-demo-api:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: shop-demo-secrets
                  key: DATABASE_URL
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: shop-demo-secrets
                  key: JWT_SECRET
            - name: JWT_EXPIRE_MINUTES
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: JWT_EXPIRE_MINUTES
            - name: UVICORN_WORKERS
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: UVICORN_WORKERS
            - name: DB_POOL_SIZE
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: DB_POOL_SIZE
            - name: DB_MAX_OVERFLOW
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: DB_MAX_OVERFLOW
            - name: DB_POOL_TIMEOUT
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: DB_POOL_TIMEOUT
            - name: DB_POOL_RECYCLE
              valueFrom:
                configMapKeyRef:
                  name: shop-demo-config
                  key: DB_POOL_RECYCLE
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: shop-demo
  labels:
    app: api
spec:
  selector:
    app: api
  ports:
    - port: 8000
      targetPort: 8000
EOF

grep -q 'idx_cart_items_user_id' "$BASE/db/init.sql" || cat >> "$BASE/db/init.sql" <<'EOF'

CREATE INDEX IF NOT EXISTS idx_cart_items_user_id ON cart_items(user_id);
EOF

cat > /home/flyluk/development/proxmox-automation/k8s-setup/shop-demo-postgres-values.yaml <<'EOF'
auth:
  username: shopuser
  database: shopdb

primary:
  persistence:
    enabled: false
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi
  extendedConfiguration: |
    max_connections = 400
    shared_buffers = 128MB
    effective_cache_size = 512MB
EOF

cat > "$BASE/k8s/redeploy-performance.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=shop-demo
API_IMAGE=shop-demo-api:latest
WEB_IMAGE=shop-demo-web:latest

echo "Building images..."
docker build -t "$API_IMAGE" "$DIR/backend"
docker build -t "$WEB_IMAGE" "$DIR/frontend"

echo "Importing into MicroK8s..."
docker save "$API_IMAGE" | microk8s ctr image import -
docker save "$WEB_IMAGE" | microk8s ctr image import -

echo "Applying config..."
kubectl apply -f "$DIR/k8s/configmap.yaml"
kubectl apply -f "$DIR/k8s/api-deployment.yaml"
kubectl apply -f "$DIR/k8s/web-deployment.yaml"

echo "Rolling out..."
kubectl rollout restart deployment/api deployment/web -n "$NS"
kubectl rollout status deployment/api -n "$NS" --timeout=300s
kubectl rollout status deployment/web -n "$NS" --timeout=300s
kubectl get pods -n "$NS" -l app=api
EOF
chmod +x "$BASE/k8s/redeploy-performance.sh"

echo "Applying DB index on running postgres..."
kubectl exec -n shop-demo shop-demo-postgres-postgresql-0 -- bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U shopuser -d shopdb -c "CREATE INDEX IF NOT EXISTS idx_cart_items_user_id ON cart_items(user_id);"' 2>/dev/null || true

echo "Done — run: $BASE/k8s/redeploy-performance.sh"
