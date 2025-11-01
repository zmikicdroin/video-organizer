import re


def extract_youtube_thumbnail(youtube_url):
    # Extract the video ID using regex
    video_id_match = re.search(r'(?:https?://)?(?:www\.)?(?:youtube\.com/(?:[^/\n]+/\S+/|(?:v|e(?:mbed)?|vi|watch|shorts)/|.*[?&]v=)|youtu\.be/)([a-zA-Z0-9_-]{11})', youtube_url)
    if not video_id_match:
        return None
    video_id = video_id_match.group(1)

    # Define possible thumbnail URLs
    thumbnail_urls = [
        f'https://img.youtube.com/vi/{video_id}/maxresdefault.jpg',
        f'https://img.youtube.com/vi/{video_id}/sddefault.jpg',
        f'https://img.youtube.com/vi/{video_id}/hqdefault.jpg'
    ]

    # Attempt to download the thumbnail from each URL
    for url in thumbnail_urls:
        try:
            response = requests.get(url)
            if response.status_code == 200:
                # Save the thumbnail
                with open(f'{video_id}.jpg', 'wb') as f:
                    f.write(response.content)
                return 'YouTube Video'
        except Exception as e:
            print(f'Error downloading thumbnail from {url}: {e}')  # Log the error

    return None
