#!/bin/bash

echo "🚀 Setting up Video Organizer Flask App..."
echo "==========================================="

# Create main project directory
PROJECT_DIR="video-organizer"
echo "📁 Creating project directory: $PROJECT_DIR"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Create subdirectories
echo "📁 Creating subdirectories..."
mkdir -p templates static/css static/js uploads thumbnails

# Create requirements.txt
echo "📝 Creating requirements.txt..."
cat > requirements.txt << 'EOF'
Flask==3.0.0
Flask-SQLAlchemy==3.1.1
yt-dlp==2023.11.16
opencv-python==4.8.1.78
Pillow==10.1.0
requests==2.31.0
Werkzeug==3.0.1
EOF

# Create app.py
echo "📝 Creating app.py..."
cat > app.py << 'ENDOFPYTHON'
from flask import Flask, render_template, request, redirect, url_for, jsonify
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import os
import cv2
import yt_dlp
from werkzeug.utils import secure_filename
from PIL import Image
import requests
from io import BytesIO

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///database.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['THUMBNAIL_FOLDER'] = 'thumbnails'
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB max file size
app.config['ALLOWED_EXTENSIONS'] = {'mp4', 'avi', 'mov', 'mkv', 'webm', 'flv'}

db = SQLAlchemy(app)

# Ensure upload and thumbnail directories exist
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
os.makedirs(app.config['THUMBNAIL_FOLDER'], exist_ok=True)

# Database Models
class Category(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    videos = db.relationship('Video', backref='category', lazy=True)

class Video(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    thumbnail_path = db.Column(db.String(300), nullable=False)
    video_path = db.Column(db.String(300))  # For uploaded videos
    youtube_url = db.Column(db.String(300))  # For YouTube links
    is_youtube = db.Column(db.Boolean, default=False)
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=False)
    upload_date = db.Column(db.DateTime, default=datetime.utcnow)

# Initialize database
with app.app_context():
    db.create_all()

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in app.config['ALLOWED_EXTENSIONS']

def extract_youtube_thumbnail(youtube_url):
    """Extract thumbnail from YouTube URL"""
    try:
        ydl_opts = {
            'quiet': True,
            'no_warnings': True,
            'extract_flat': True,
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(youtube_url, download=False)
            thumbnail_url = info.get('thumbnail')
            video_title = info.get('title', 'YouTube Video')
            
            # Download thumbnail
            response = requests.get(thumbnail_url)
            img = Image.open(BytesIO(response.content))
            
            # Save thumbnail
            timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
            thumbnail_filename = f'yt_{timestamp}.jpg'
            thumbnail_path = os.path.join(app.config['THUMBNAIL_FOLDER'], thumbnail_filename)
            img.save(thumbnail_path)
            
            return thumbnail_filename, video_title
    except Exception as e:
        print(f"Error extracting YouTube thumbnail: {e}")
        return None, None

def generate_video_thumbnail(video_path):
    """Generate thumbnail from uploaded video"""
    try:
        cap = cv2.VideoCapture(video_path)
        
        # Get video frame at 1 second
        fps = cap.get(cv2.CAP_PROP_FPS)
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(fps * 1))
        
        ret, frame = cap.read()
        cap.release()
        
        if ret:
            timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
            thumbnail_filename = f'video_{timestamp}.jpg'
            thumbnail_path = os.path.join(app.config['THUMBNAIL_FOLDER'], thumbnail_filename)
            
            cv2.imwrite(thumbnail_path, frame)
            return thumbnail_filename
        return None
    except Exception as e:
        print(f"Error generating thumbnail: {e}")
        return None

@app.route('/')
def index():
    categories = Category.query.all()
    
    # Get videos grouped by category
    videos_by_category = {}
    for category in categories:
        videos_by_category[category.name] = Video.query.filter_by(category_id=category.id).all()
    
    return render_template('index.html', categories=categories, videos_by_category=videos_by_category)

@app.route('/calendar')
def calendar():
    videos = Video.query.order_by(Video.upload_date.desc()).all()
    
    # Group videos by date
    videos_by_date = {}
    for video in videos:
        date_key = video.upload_date.strftime('%Y-%m-%d')
        if date_key not in videos_by_date:
            videos_by_date[date_key] = []
        videos_by_date[date_key].append(video)
    
    return render_template('calendar.html', videos_by_date=videos_by_date)

@app.route('/add_category', methods=['POST'])
def add_category():
    category_name = request.form.get('category_name')
    
    if category_name:
        existing = Category.query.filter_by(name=category_name).first()
        if not existing:
            new_category = Category(name=category_name)
            db.session.add(new_category)
            db.session.commit()
    
    return redirect(url_for('index'))

@app.route('/add_youtube', methods=['POST'])
def add_youtube():
    youtube_url = request.form.get('youtube_url')
    category_id = request.form.get('category_id')
    
    if youtube_url and category_id:
        thumbnail_filename, video_title = extract_youtube_thumbnail(youtube_url)
        
        if thumbnail_filename:
            new_video = Video(
                title=video_title,
                thumbnail_path=thumbnail_filename,
                youtube_url=youtube_url,
                is_youtube=True,
                category_id=category_id
            )
            db.session.add(new_video)
            db.session.commit()
    
    return redirect(url_for('index'))

@app.route('/upload_video', methods=['POST'])
def upload_video():
    if 'video_file' not in request.files:
        return redirect(url_for('index'))
    
    file = request.files['video_file']
    category_id = request.form.get('category_id')
    video_title = request.form.get('video_title', 'Untitled Video')
    
    if file and allowed_file(file.filename) and category_id:
        filename = secure_filename(file.filename)
        timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
        filename = f"{timestamp}_{filename}"
        video_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        
        file.save(video_path)
        
        # Generate thumbnail
        thumbnail_filename = generate_video_thumbnail(video_path)
        
        if thumbnail_filename:
            new_video = Video(
                title=video_title,
                thumbnail_path=thumbnail_filename,
                video_path=filename,
                is_youtube=False,
                category_id=category_id
            )
            db.session.add(new_video)
            db.session.commit()
    
    return redirect(url_for('index'))

@app.route('/get_categories')
def get_categories():
    categories = Category.query.all()
    return jsonify([{'id': c.id, 'name': c.name} for c in categories])

@app.route('/delete_video/<int:video_id>', methods=['POST'])
def delete_video(video_id):
    video = Video.query.get_or_404(video_id)
    
    # Delete thumbnail file
    thumbnail_path = os.path.join(app.config['THUMBNAIL_FOLDER'], video.thumbnail_path)
    if os.path.exists(thumbnail_path):
        os.remove(thumbnail_path)
    
    # Delete video file if it's an upload
    if not video.is_youtube and video.video_path:
        video_path = os.path.join(app.config['UPLOAD_FOLDER'], video.video_path)
        if os.path.exists(video_path):
            os.remove(video_path)
    
    db.session.delete(video)
    db.session.commit()
    
    return redirect(request.referrer or url_for('index'))

if __name__ == '__main__':
    app.run(debug=True)
ENDOFPYTHON

# Create index.html
echo "📝 Creating templates/index.html..."
cat > templates/index.html << 'ENDOFHTML1'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Video Organizer - Gallery</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
    <nav class="navbar">
        <h1>📹 Video Organizer</h1>
        <div class="nav-links">
            <a href="{{ url_for('index') }}" class="active">Gallery</a>
            <a href="{{ url_for('calendar') }}">Calendar</a>
        </div>
    </nav>

    <div class="container">
        <!-- Add Category Section -->
        <div class="section">
            <h2>➕ Create New Category</h2>
            <form action="{{ url_for('add_category') }}" method="POST" class="form-inline">
                <input type="text" name="category_name" placeholder="Enter category name" required>
                <button type="submit" class="btn btn-primary">Add Category</button>
            </form>
        </div>

        <!-- Add YouTube Link Section -->
        <div class="section">
            <h2>🔗 Add YouTube Link</h2>
            <form action="{{ url_for('add_youtube') }}" method="POST" class="form-inline">
                <input type="url" name="youtube_url" placeholder="Enter YouTube URL" required>
                <select name="category_id" required>
                    <option value="">Select Category</option>
                    {% for category in categories %}
                    <option value="{{ category.id }}">{{ category.name }}</option>
                    {% endfor %}
                </select>
                <button type="submit" class="btn btn-primary">Add YouTube Link</button>
            </form>
        </div>

        <!-- Upload Video Section -->
        <div class="section">
            <h2>📤 Upload Video</h2>
            <form action="{{ url_for('upload_video') }}" method="POST" enctype="multipart/form-data" class="form-inline">
                <input type="text" name="video_title" placeholder="Video title" required>
                <input type="file" name="video_file" accept="video/*" required>
                <select name="category_id" required>
                    <option value="">Select Category</option>
                    {% for category in categories %}
                    <option value="{{ category.id }}">{{ category.name }}</option>
                    {% endfor %}
                </select>
                <button type="submit" class="btn btn-primary">Upload Video</button>
            </form>
        </div>

        <!-- Categories Gallery -->
        <div class="section">
            <h2>🗂️ Video Gallery by Category</h2>
            {% if videos_by_category %}
                {% for category_name, videos in videos_by_category.items() %}
                    {% if videos %}
                    <div class="category-section">
                        <h3 class="category-title">{{ category_name }}</h3>
                        <div class="video-grid">
                            {% for video in videos %}
                            <div class="video-card">
                                <div class="thumbnail-container">
                                    {% if video.is_youtube %}
                                        <a href="{{ video.youtube_url }}" target="_blank">
                                            <img src="{{ url_for('static', filename='../thumbnails/' + video.thumbnail_path) }}" alt="{{ video.title }}">
                                            <div class="play-overlay">▶️</div>
                                        </a>
                                    {% else %}
                                        <a href="{{ url_for('static', filename='../uploads/' + video.video_path) }}" target="_blank">
                                            <img src="{{ url_for('static', filename='../thumbnails/' + video.thumbnail_path) }}" alt="{{ video.title }}">
                                            <div class="play-overlay">▶️</div>
                                        </a>
                                    {% endif %}
                                </div>
                                <div class="video-info">
                                    <h4>{{ video.title }}</h4>
                                    <p class="video-date">{{ video.upload_date.strftime('%Y-%m-%d %H:%M') }}</p>
                                    <span class="badge">{{ 'YouTube' if video.is_youtube else 'Uploaded' }}</span>
                                    <form action="{{ url_for('delete_video', video_id=video.id) }}" method="POST" style="display:inline;">
                                        <button type="submit" class="btn-delete" onclick="return confirm('Delete this video?')">🗑️</button>
                                    </form>
                                </div>
                            </div>
                            {% endfor %}
                        </div>
                    </div>
                    {% endif %}
                {% endfor %}
            {% else %}
                <p class="empty-state">No videos yet. Add some YouTube links or upload videos!</p>
            {% endif %}
        </div>
    </div>

    <script src="{{ url_for('static', filename='js/script.js') }}"></script>
</body>
</html>
ENDOFHTML1

# Create calendar.html
echo "📝 Creating templates/calendar.html..."
cat > templates/calendar.html << 'ENDOFHTML2'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Video Organizer - Calendar</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
    <nav class="navbar">
        <h1>📅 Video Organizer - Calendar View</h1>
        <div class="nav-links">
            <a href="{{ url_for('index') }}">Gallery</a>
            <a href="{{ url_for('calendar') }}" class="active">Calendar</a>
        </div>
    </nav>

    <div class="container">
        <div class="section">
            <h2>📆 Videos by Upload Date</h2>
            {% if videos_by_date %}
                <div class="calendar-view">
                    {% for date, videos in videos_by_date.items() %}
                    <div class="date-section">
                        <h3 class="date-header">{{ date }}</h3>
                        <div class="video-grid">
                            {% for video in videos %}
                            <div class="video-card">
                                <div class="thumbnail-container">
                                    {% if video.is_youtube %}
                                        <a href="{{ video.youtube_url }}" target="_blank">
                                            <img src="{{ url_for('static', filename='../thumbnails/' + video.thumbnail_path) }}" alt="{{ video.title }}">
                                            <div class="play-overlay">▶️</div>
                                        </a>
                                    {% else %}
                                        <a href="{{ url_for('static', filename='../uploads/' + video.video_path) }}" target="_blank">
                                            <img src="{{ url_for('static', filename='../thumbnails/' + video.thumbnail_path) }}" alt="{{ video.title }}">
                                            <div class="play-overlay">▶️</div>
                                        </a>
                                    {% endif %}
                                </div>
                                <div class="video-info">
                                    <h4>{{ video.title }}</h4>
                                    <p class="video-category">Category: {{ video.category.name }}</p>
                                    <p class="video-time">{{ video.upload_date.strftime('%H:%M') }}</p>
                                    <span class="badge">{{ 'YouTube' if video.is_youtube else 'Uploaded' }}</span>
                                    <form action="{{ url_for('delete_video', video_id=video.id) }}" method="POST" style="display:inline;">
                                        <button type="submit" class="btn-delete" onclick="return confirm('Delete this video?')">🗑️</button>
                                    </form>
                                </div>
                            </div>
                            {% endfor %}
                        </div>
                    </div>
                    {% endfor %}
                </div>
            {% else %}
                <p class="empty-state">No videos uploaded yet!</p>
            {% endif %}
        </div>
    </div>

    <script src="{{ url_for('static', filename='js/script.js') }}"></script>
</body>
</html>
ENDOFHTML2

# Create style.css
echo "📝 Creating static/css/style.css..."
cat > static/css/style.css << 'ENDOFCSS'
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    min-height: 100vh;
    color: #333;
}

.navbar {
    background: rgba(255, 255, 255, 0.95);
    padding: 1.5rem 2rem;
    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.navbar h1 {
    color: #667eea;
    font-size: 1.8rem;
}

.nav-links {
    display: flex;
    gap: 1rem;
}

.nav-links a {
    text-decoration: none;
    color: #555;
    padding: 0.5rem 1.5rem;
    border-radius: 20px;
    transition: all 0.3s;
    font-weight: 500;
}

.nav-links a:hover, .nav-links a.active {
    background: #667eea;
    color: white;
}

.container {
    max-width: 1400px;
    margin: 2rem auto;
    padding: 0 2rem;
}

.section {
    background: white;
    border-radius: 15px;
    padding: 2rem;
    margin-bottom: 2rem;
    box-shadow: 0 5px 20px rgba(0,0,0,0.1);
}

.section h2 {
    color: #667eea;
    margin-bottom: 1.5rem;
    font-size: 1.5rem;
}

.form-inline {
    display: flex;
    gap: 1rem;
    flex-wrap: wrap;
}

.form-inline input[type="text"],
.form-inline input[type="url"],
.form-inline input[type="file"],
.form-inline select {
    flex: 1;
    min-width: 200px;
    padding: 0.75rem;
    border: 2px solid #e0e0e0;
    border-radius: 8px;
    font-size: 1rem;
    transition: border 0.3s;
}

.form-inline input:focus,
.form-inline select:focus {
    outline: none;
    border-color: #667eea;
}

.btn {
    padding: 0.75rem 2rem;
    border: none;
    border-radius: 8px;
    font-size: 1rem;
    cursor: pointer;
    transition: all 0.3s;
    font-weight: 600;
}

.btn-primary {
    background: #667eea;
    color: white;
}

.btn-primary:hover {
    background: #5568d3;
    transform: translateY(-2px);
    box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
}

.category-section {
    margin-bottom: 3rem;
}

.category-title {
    color: #764ba2;
    font-size: 1.3rem;
    margin-bottom: 1rem;
    padding-bottom: 0.5rem;
    border-bottom: 3px solid #667eea;
}

.video-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1.5rem;
    margin-top: 1rem;
}

.video-card {
    background: #f8f9fa;
    border-radius: 12px;
    overflow: hidden;
    transition: transform 0.3s, box-shadow 0.3s;
}

.video-card:hover {
    transform: translateY(-5px);
    box-shadow: 0 10px 25px rgba(0,0,0,0.15);
}

.thumbnail-container {
    position: relative;
    width: 100%;
    padding-top: 56.25%;
    overflow: hidden;
    background: #000;
}

.thumbnail-container img {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.play-overlay {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    font-size: 3rem;
    opacity: 0;
    transition: opacity 0.3s;
}

.thumbnail-container:hover .play-overlay {
    opacity: 0.9;
}

.video-info {
    padding: 1rem;
}

.video-info h4 {
    color: #333;
    margin-bottom: 0.5rem;
    font-size: 1.1rem;
}

.video-date, .video-category, .video-time {
    color: #666;
    font-size: 0.9rem;
    margin-bottom: 0.5rem;
}

.badge {
    display: inline-block;
    padding: 0.25rem 0.75rem;
    background: #667eea;
    color: white;
    border-radius: 12px;
    font-size: 0.85rem;
    margin-right: 0.5rem;
}

.btn-delete {
    background: #ff4757;
    color: white;
    border: none;
    padding: 0.25rem 0.75rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: 1rem;
    transition: background 0.3s;
}

.btn-delete:hover {
    background: #ee3344;
}

.empty-state {
    text-align: center;
    color: #999;
    font-size: 1.2rem;
    padding: 3rem;
}

.date-section {
    margin-bottom: 2rem;
}

.date-header {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: white;
    padding: 1rem;
    border-radius: 8px;
    margin-bottom: 1rem;
    font-size: 1.2rem;
}

.calendar-view {
    margin-top: 2rem;
}

@media (max-width: 768px) {
    .navbar {
        flex-direction: column;
        gap: 1rem;
    }
    
    .form-inline {
        flex-direction: column;
    }
    
    .form-inline input,
    .form-inline select {
        width: 100%;
    }
    
    .video-grid {
        grid-template-columns: 1fr;
    }
}
ENDOFCSS

# Create script.js
echo "📝 Creating static/js/script.js..."
cat > static/js/script.js << 'ENDOFJS'
document.addEventListener('DOMContentLoaded', function() {
    const forms = document.querySelectorAll('form');
    
    forms.forEach(form => {
        form.addEventListener('submit', function(e) {
            const submitBtn = form.querySelector('button[type="submit"]');
            if (submitBtn) {
                submitBtn.disabled = true;
                submitBtn.textContent = 'Processing...';
            }
        });
    });

    const fileInput = document.querySelector('input[type="file"]');
    if (fileInput) {
        fileInput.addEventListener('change', function(e) {
            const file = e.target.files[0];
            if (file) {
                const fileSize = (file.size / 1024 / 1024).toFixed(2);
                console.log('Selected file: ' + file.name + ' (' + fileSize + ' MB)');
                
                if (fileSize > 500) {
                    alert('File size exceeds 500MB limit!');
                    fileInput.value = '';
                }
            }
        });
    }

    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                target.scrollIntoView({
                    behavior: 'smooth'
                });
            }
        });
    });
});
ENDOFJS

# Create .gitkeep files
touch uploads/.gitkeep
touch thumbnails/.gitkeep

echo ""
echo "✅ Setup complete!"
echo ""
echo "📂 Project created in: $PROJECT_DIR/"
echo ""
echo "🚀 Next steps:"
echo "   1. cd $PROJECT_DIR"
echo "   2. pip install -r requirements.txt"
echo "   3. python app.py"
echo "   4. Open http://127.0.0.1:5000"
echo ""
echo "🎉 Happy organizing!"
