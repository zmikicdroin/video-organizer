FROM python:3.8-slim

# Install OpenCV dependencies
RUN apt-get update && apt-get install -y \
    libgl1-mesa-glx \
    libxrender1 \
    libfontconfig1 \
    libice6 \
    && rm -rf /var/lib/apt/lists/*

# Set permissions for directories
RUN chmod -R 777 /path/to/uploads /path/to/thumbnails /path/to/instance

# Set working directory
WORKDIR /app

# Copy application files
COPY . .

# Install Python dependencies
RUN pip install -r requirements.txt

# Command to run the application
CMD gunicorn --access-logfile "-" --error-logfile "-" myapp:app