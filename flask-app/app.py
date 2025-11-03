import os
from flask import Flask, render_template, send_from_directory, abort
from prometheus_client import Counter, Histogram, generate_latest
import time
import random


# Base directory containing index.html, css, js and images
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Configure Flask to use this folder for templates and static files
app = Flask(__name__, static_folder=BASE_DIR, static_url_path='', template_folder=BASE_DIR)

# Prometheus metrics (minimal: count + latency per endpoint)
REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP Requests', ['endpoint'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'Request latency', ['endpoint'])
                            
@app.route('/')
def index():
    REQUEST_COUNT.labels(endpoint='/').inc()
    with REQUEST_LATENCY.labels(endpoint='/').time():
        time.sleep(random.uniform(0.1, 0.5))  # Optional sim delay
    # Serve the main HTML page
        return send_from_directory(BASE_DIR, 'index.html')

@app.route('/<path:filename>')
def serve_file(filename):
    # Prevent path traversal attacks
    if '..' in filename or filename.startswith('/'):
        abort(404)
    return send_from_directory(BASE_DIR, filename)

@app.route('/payment')
def payment():
    REQUEST_COUNT.labels(endpoint='/payment').inc()
    with REQUEST_LATENCY.labels(endpoint='/payment').time():
        time.sleep(random.uniform(0.05, 0.2))
        return send_from_directory(BASE_DIR, 'payment.html')

@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': 'text/plain'}

if __name__ == '__main__':
    # Run on all interfaces so the app is reachable from other hosts if needed
    app.run(host='0.0.0.0', port=5000, debug=True)
