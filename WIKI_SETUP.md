# GitHub Wiki Setup

Wiki documentation has been prepared in the `wiki/` directory. To publish it to GitHub:

## Option 1: Automatic (Recommended)

1. Ensure the wiki is enabled in GitHub settings:
   - Go to https://github.com/lenik/img2mp4/settings
   - Scroll to "Features" section
   - Ensure "Wikis" is checked

2. Push the wiki content:
   ```bash
   cd wiki
   git init
   git add *.md
   git commit -m "Initial wiki documentation"
   git remote add origin git@github.com:lenik/img2mp4.wiki.git
   git push -u origin main
   ```

## Option 2: Manual Upload

1. Go to https://github.com/lenik/img2mp4/wiki
2. Click "Create the first page"
3. Copy content from each `.md` file in the `wiki/` directory
4. Create pages for:
   - Home.md (set as home page)
   - Installation.md
   - Usage.md
   - Examples.md
   - Advanced.md
   - Troubleshooting.md

## Wiki Pages Created

- **Home.md** - Main overview and quick start
- **Installation.md** - Installation instructions for all platforms
- **Usage.md** - Complete command-line reference
- **Examples.md** - Common use cases and examples
- **Advanced.md** - Advanced topics and integration
- **Troubleshooting.md** - Common issues and solutions

All files are ready in the `wiki/` directory.

