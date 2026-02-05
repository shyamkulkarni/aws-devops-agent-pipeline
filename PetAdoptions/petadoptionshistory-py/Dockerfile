# syntax=docker/dockerfile:1

FROM python:3.11-slim

WORKDIR /app

# prerequisites for building psycopg2
RUN apt-get update && apt-get install -y build-essential python3-dev libpq-dev && rm -rf /var/lib/apt/lists/*

COPY requirements.txt requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt

COPY . .
ENV FLASK_APP=petadoptionshistory
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

CMD [ "flask", "run" , "--host=0.0.0.0", "--port=8080"]

EXPOSE 8080/tcp