from flask import Flask, render_template, request, redirect, url_for, jsonify, send_from_directory
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

# Serve uploaded videos
@app.route('/uploads/<filename>')
def uploaded_file(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

# Serve thumbnails
@app.route('/thumbnails/<filename>')
def thumbnail_file(filename):
    return send_from_directory(app.config['THUMBNAIL_FOLDER'], filename)

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
    # Run on all network interfaces to allow local network access
    app.run(host='0.0.0.0', port=5000, debug=True)
