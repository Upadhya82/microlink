FROM python:3.12-slim

WORKDIR /app

RUN apt-get -o Acquire::Retries=10 update && apt-get -o Acquire::Retries=10 install -y --no-install-recommends gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --retries 10 --timeout 120 --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
