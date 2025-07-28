# Price Tracker - Web Scraping Application - Prices!! Yippie!

Normally I never do Read.me's but since this project contains both a proper front-end and back end, I figured it would be useful for review.

## Features

- **Real-time Web Scraping**: Real-time console output of scraping process
- **Multi-Platform Support**: Amazon, eBay, Best Buy
- **Hybrid Price Tracking**: Web scraping and manual price input combination
- **Price History**: Record price over time
- **Intelligent Validation**: Intelligent price selection, confidence scoring
- **Responsive Design**: Modern UI using Tailwind CSS
- **Security Features**: CSRF protection, rate limiting, URL validation

## Tech Stack

- **Backend**: Ruby with Sinatra framework
- **Database**: JSON for data storage
- **Frontend**: HTML, Tailwind CSS, JavaScript
- **Web Scraping**: Nokogiri and HTTParty gems
- **Real-time**: Server-Sent Events (SSE)
- **Templates**: ERB (Embedded Ruby)

## Installation

1. **Prerequisites**
   ```bash
   # Ensure Ruby 3.0+ is installed
   ruby --version
   ```

2. **Clone and Setup**
   ```bash
   git clone <repository-url>
   cd price-tracker
   bundle install
   ```

3. **Run the Application**
   ```bash
   ruby app.rb
   ```

4. **Access the Application**
   - Open `http://localhost:4567` in your web browser
   - Dashboard: `http://localhost:4567/`
   - Products: `http://localhost:4567/products`


### Adding Products - Enter an Amazon, eBay, or Best Buy product URL,  Optionally provide current price and target price, Submit to see live scraping output in the console

### Live Console - Watch live scraping process with verbose logging, errors, etc.

### Price Tracking - View all tracked products with current prices

## Security Features

- **CSRF Protection**: CSRF tokens on all forms
- **Rate Limiting**: Prevention of abuses with request limits
- **URL Validation**: Only allow HTTPS URLs from whitelisted domains
- **Input Sanitization**: User inputs validated and sanitized

## API Endpoints

- `GET /` - Dashboard
- `GET /products` - Products list
- `POST /products` - New product creation
- `GET /products/:id/refresh` - Refresh product price
- `POST /products/:id/delete` - Delete product
- `GET /console/stream` - Real-time console output (SSE)
- `GET /api/status` - API status check
- `GET /api/test-console` - Test console functionality

## Project Structure

```bash
price-tracker/
├── app.rb                 # Main Sinatra application
├── hybrid_tracker.rb      # Core scraping logic
```
├── Gemfile               # Ruby dependencies
├── config.ru             # Rack configuration
├── views/                # ERB templates
│   ├── layout.erb        # Main layout
│   ├── dashboard.erb     # Dashboard page
│   ├── products.erb      # Products page
│   └── about.erb         # About page
└── database/             # JSON data storage
    ├── price_tracker.json
    └── target_prices.json

## Performance Optimizations

- **Caching**: In-memory cache for recent scrape results
- **Optimized Parsing**: Less HTML parsing for large pages
- **Retry Logic**: Automatic retry for failed requests
- **Message Batching**: Frontend optimization for console output

## License

This project is for demonstration and educational purposes, use it however youd like!

## Disclaimer

This is a learning project demonstrating web scraping capabilities. Scraped prices are estimates and may not reflect current actual prices. Web scraping obstacles consist of anti-bot measures, dynamic content, and changing website architectures.