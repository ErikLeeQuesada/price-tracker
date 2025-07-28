require 'sinatra'
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require_relative 'hybrid_tracker'

# Enable sessions for flash messages
enable :sessions

# CSRF protection
before do
  if request.post? || request.put? || request.delete?
    unless request.path_info == '/console/stream'  # Skip for SSE
      csrf_token = params['csrf_token'] || request.env['HTTP_X_CSRF_TOKEN']
      unless csrf_token && csrf_token == session[:csrf_token]
        halt 403, 'CSRF token missing or invalid'
      end
    end
  end
end

# Generate CSRF token for all routes
before do
  session[:csrf_token] ||= SecureRandom.hex(32)
end

# Global tracker instance for SSE
$global_tracker = nil

# Simple rate limiting
$request_counts = {}
$rate_limit_window = 60  # 1 minute window
$max_requests_per_window = 10  # Max 10 requests per minute

# Initialize our price tracker
before do
  @tracker = $global_tracker || HybridPriceTracker.new
end

# Rate limiting helper
def check_rate_limit(ip)
  now = Time.now.to_i
  window_start = now - $rate_limit_window
  
  # Clean old entries
  $request_counts.delete_if { |_, timestamp| timestamp < window_start }
  
  # Count requests in current window
  current_count = $request_counts.count { |_, timestamp| timestamp >= window_start }
  
  if current_count >= $max_requests_per_window
    return false
  else
    $request_counts[ip] = now
    return true
  end
end

# Root route - render dashboard
get '/' do
  @products = get_all_products
  erb :dashboard
end

# About route
get '/about' do
  erb :about
end

# Products list
get '/products' do
  @products = get_all_products
  erb :products
end

# Server-Sent Events endpoint for real-time console output
get '/console/stream' do
  content_type 'text/event-stream'
  cache_control :no_cache
  
  stream(:keep_open) do |out|
    # Create a new tracker instance for this stream
    tracker = HybridPriceTracker.new
    
    # Store the stream callback in the tracker
    tracker.set_log_stream(->(message) {
      out << "data: #{message}\n\n"
    })
    
    # Store the tracker globally so the scraping can use it
    $global_tracker = tracker
    
    # Send initial connection message
    out << "data: [CONSOLE] Connected to live console stream\n\n"
    out << "data: [READY] Console ready for scraping output\n\n"
    
    # Keep connection alive with heartbeat
    loop do
      out << "data: [HEARTBEAT] #{Time.now.strftime('%H:%M:%S')}\n\n"
      sleep 30
    end
  rescue => e
    out << "data: [ERROR] Console stream error: #{e.message}\n\n"
  ensure
    tracker.set_log_stream(nil)
    $global_tracker = nil
  end
end

# Create product (handle form submission)
post '/products' do
  # Rate limiting
  client_ip = request.ip
  unless check_rate_limit(client_ip)
    error_msg = "Rate limit exceeded. Please wait before making more requests."
    if request.xhr?
      content_type :json
      return { error: error_msg }.to_json
    else
      session[:flash] = { error: error_msg }
      redirect '/'
    end
  end
  
  url = params[:url]
  current_price = params[:current_price].to_f if params[:current_price] && !params[:current_price].empty?
  target_price = params[:target_price].to_f if params[:target_price] && !params[:target_price].empty?
  
  # Validate URL
  if url.nil? || url.empty?
    if request.xhr?
      content_type :json
      return { error: "Please provide a product URL" }.to_json
    else
      session[:flash] = { error: "Please provide a product URL" }
      redirect '/products/new'
    end
  end
  
  # Security: Validate URL format and allowed domains
  begin
    uri = URI.parse(url)
    allowed_domains = ['amazon.com', 'amazon.co.uk', 'amazon.ca', 'amazon.de', 'amazon.fr', 'amazon.it', 'amazon.es', 'amazon.co.jp', 'amazon.in', 'amazon.com.au', 'amazon.com.mx', 'amazon.com.br', 'ebay.com', 'ebay.co.uk', 'ebay.ca', 'ebay.de', 'ebay.fr', 'ebay.it', 'ebay.es', 'ebay.com.au', 'bestbuy.com', 'bestbuy.ca']
    
    unless allowed_domains.any? { |domain| uri.host&.downcase&.include?(domain) }
      error_msg = "Only Amazon, eBay, and Best Buy URLs are allowed"
      if request.xhr?
        content_type :json
        return { error: error_msg }.to_json
      else
        session[:flash] = { error: error_msg }
        redirect '/'
      end
    end
    
    # Ensure HTTPS for security
    unless uri.scheme == 'https'
      error_msg = "Only HTTPS URLs are allowed for security"
      if request.xhr?
        content_type :json
        return { error: error_msg }.to_json
      else
        session[:flash] = { error: error_msg }
        redirect '/'
      end
    end
    
  rescue URI::InvalidURIError
    error_msg = "Invalid URL format"
    if request.xhr?
      content_type :json
      return { error: error_msg }.to_json
    else
      session[:flash] = { error: error_msg }
      redirect '/'
    end
  end
  
  begin
    # For AJAX requests, ensure console is ready before scraping
    if request.xhr?
      # Small delay to ensure console connection is established
      sleep 0.5
    end
    
    # Use the global tracker that has the log stream set up
    tracker_to_use = request.xhr? ? $global_tracker : @tracker
    
    # Ensure global tracker is available for AJAX requests
    if request.xhr? && !$global_tracker
      $global_tracker = HybridPriceTracker.new
    end
    
    # Use our hybrid tracker to get the price
    result = tracker_to_use.get_current_price(url, current_price)
    
    if result[:price]
      # Save target price if provided
      if target_price
        save_target_price(url, target_price)
      end
      
      if request.xhr?
        content_type :json
        return { 
          success: true,
          price: result[:price],
          confidence: result[:confidence],
          title: result[:title],
          message: "Product added! Current price: $#{result[:price]} (#{result[:confidence]}% confidence)"
        }.to_json
      else
        session[:flash] = { 
          notice: "Product added! Current price: $#{result[:price]} (#{result[:confidence]}% confidence)" 
        }
        redirect '/'
      end
    else
      # Better error handling with more specific messages
      error_msg = case result[:source]
      when 'scrape_failed'
        "Could not extract price from this page. The website structure may have changed."
      when 'fetch_failed'
        "Could not access the website. Please check the URL."
      when 'scrape_error'
        "Scraping error: #{result[:error] || 'Unknown error'}"
      else
        "Could not get price for this product. Please check the URL and try again."
      end
      
      if request.xhr?
        content_type :json
        return { error: error_msg }.to_json
      else
        session[:flash] = { error: error_msg }
        redirect '/'
      end
    end
    
  rescue => e
    if request.xhr?
      content_type :json
      return { error: "Error: #{e.message}" }.to_json
    else
      session[:flash] = { error: "Error: #{e.message}" }
      redirect '/products/new'
    end
  end
end



# Refresh product price
get '/products/:id/refresh' do
  product_id = params[:id]
  product = get_product_by_id(product_id)
  
  if product
    begin
      result = @tracker.get_current_price(product[:url])
      
      if result[:price]
        session[:flash] = { 
          notice: "Price updated! New price: $#{result[:price]} (#{result[:confidence]}% confidence)" 
        }
      else
        session[:flash] = { error: "Could not refresh price for this product" }
      end
    rescue => e
      session[:flash] = { error: "Error refreshing price: #{e.message}" }
    end
  else
    session[:flash] = { error: "Product not found" }
  end
  
  redirect '/products'
end

# Delete product
post '/products/:id/delete' do
  product_id = params[:id]
  product = get_product_by_id(product_id)
  
  if product
    begin
      result = @tracker.delete_product(product[:url])
      
      if result[:success]
        session[:flash] = { 
          notice: "Product deleted! Removed #{result[:deleted_count]} price records." 
        }
      else
        session[:flash] = { error: result[:message] }
      end
    rescue => e
      session[:flash] = { error: "Error deleting product: #{e.message}" }
    end
  else
    session[:flash] = { error: "Product not found" }
  end
  
  redirect '/products'
end



# API routes
get '/api/status' do
  content_type :json
  { 
    status: 'running',
    message: 'Price tracker API is working!',
    timestamp: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
    products_tracked: get_all_products.length
  }.to_json
end

# Test console logging
get '/api/test-console' do
  if $global_tracker
    $global_tracker.log("[TEST] This is a test message from the API")
    $global_tracker.log("[TEST] Another test message")
    $global_tracker.log("[TEST] Console logging is working!")
    content_type :json
    { success: true, message: "Test messages sent to console" }.to_json
  else
    content_type :json
    { success: false, message: "No global tracker available" }.to_json
  end
end



# Helper methods
def get_all_products
  products = @tracker.get_all_products
  
  # Convert to the format expected by the template
  products.map do |product|
    {
      id: Digest::MD5.hexdigest(product[:url])[0..7], # Short ID from URL hash
      url: product[:url],
      title: product[:title] || 'Unknown Product',
      price: product[:price],
      confidence: product[:confidence] || 0,
      source: product[:source],
      last_updated: product[:last_updated],
      target_price: get_target_price(product[:url])
    }
  end.sort_by { |p| p[:last_updated] }.reverse
end

def get_product_by_id(product_id)
  products = get_all_products
  products.find { |p| p[:id] == product_id }
end

def save_target_price(url, target_price)
  # Save target prices in a separate JSON file for simplicity
  targets_path = 'database/target_prices.json'
  
  # Create directory if it doesn't exist
  FileUtils.mkdir_p(File.dirname(targets_path))
  
  # Load existing targets
  targets = {}
  if File.exist?(targets_path)
    begin
      targets = JSON.parse(File.read(targets_path))
    rescue JSON::ParserError
      targets = {}
    end
  end
  
  # Save new target
  targets[url] = target_price
  
  # Write back to file
  File.write(targets_path, JSON.generate(targets, pretty: true))
  # Set restrictive permissions
  File.chmod(0600, targets_path) if File.exist?(targets_path)
  
  puts "Saved target price $#{target_price} for #{url}"
rescue => e
  puts "Error saving target price: #{e.message}"
end

def get_target_price(url)
  targets_path = 'database/target_prices.json'
  return nil unless File.exist?(targets_path)
  
  begin
    targets = JSON.parse(File.read(targets_path))
    targets[url]
  rescue
    nil
  end
end

# Configure Sinatra
configure do
  set :port, 4567
  set :bind, '0.0.0.0'
end

# Flash message helper for templates
helpers do
  def flash
    session[:flash]
  end
end

# Helper method for shortening URLs
def shorten_url(url)
  begin
    uri = URI.parse(url)
    domain = uri.host
    path = uri.path
    
    # Keep the domain and first part of the path
    if path.length > 30
      path = path[0..30] + "..."
    end
    
    "#{domain}#{path}"
  rescue
    # Fallback if URL parsing fails
    if url.length > 50
      url[0..50] + "..."
    else
      url
    end
  end
end

# Clear flash after displaying
after do
  session[:flash] = nil if session[:flash]
end

puts "Starting Price Tracker with Product Management on http://localhost:4567"