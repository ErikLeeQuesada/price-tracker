require 'nokogiri'
require 'httparty'
require 'uri'
require 'json'
require 'fileutils'

class HybridPriceTracker
  def initialize(db_path = 'database/price_tracker.json')
    @db_path = db_path
    @log_stream = nil
    @cache = {}  # Simple in-memory cache
    @cache_ttl = 300  # 5 minutes cache TTL
    setup_database
    puts "Hybrid Price Tracker initialized!"
    puts "Database: #{db_path}"
  end
  
  # Set the log stream for real-time output
  def set_log_stream(stream)
    @log_stream = stream
  end
  
  # Helper method to log with streaming support
  def log(message)
    puts message
    if @log_stream
      @log_stream.call(message)
    end
  end
  
  def get_current_price(url, user_reported_price = nil)
    log("[HYBRID] Getting price for: #{url}")
    
    # Check cache first
    cache_key = "#{url}_#{user_reported_price}"
    if @cache[cache_key] && @cache[cache_key][:expires_at] > Time.now
      log("[CACHE] Using cached result for: #{url}")
      return @cache[cache_key][:data]
    end
    
    scraped_result = attempt_scraping(url)
    
    if user_reported_price
      validated_price = validate_price(scraped_result, user_reported_price, url)
    else
      validated_price = scraped_result
    end
    
    result = {
      price: validated_price[:price],
      confidence: validated_price[:confidence],
      source: validated_price[:source],
      title: validated_price[:title],
      last_updated: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
      needs_user_input: validated_price[:needs_user_input] || false,
      suggestion: validated_price[:suggestion],
      error: validated_price[:error]
    }
    
    if validated_price[:price]
      save_price_record(url, validated_price)
    end
    
    # Cache the result
    @cache[cache_key] = {
      data: result,
      expires_at: Time.now + @cache_ttl
    }
    
    result
  end
  
  def get_price_history(url, days = 30)
    cutoff_date = Time.now - (days * 24 * 60 * 60)
    
    records = load_database
    url_records = records.select { |record| record['url'] == url }
    
    recent_records = url_records.select do |record|
      begin
        date_str = record['recorded_at']
        year, month, day, hour, min, sec = date_str.match(/(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/).captures.map(&:to_i)
        record_time = Time.new(year, month, day, hour, min, sec)
        record_time > cutoff_date
      rescue
        false
      end
    end
    
    recent_records.map do |record|
      {
        price: record['price'],
        source: record['source'],
        confidence: record['confidence'],
        recorded_at: record['recorded_at'],
        title: record['title']
      }
    end.sort_by { |r| r[:recorded_at] }.reverse
  end
  

  
  def get_all_products
    records = load_database
    
    # Group by URL and get the latest record for each product
    products = {}
    records.each do |record|
      url = record['url']
      if !products[url] || record['recorded_at'] > products[url]['recorded_at']
        products[url] = record
      end
    end
    
    products.values.map do |record|
      {
        url: record['url'],
        title: record['title'],
        price: record['price'],
        source: record['source'],
        confidence: record['confidence'],
        last_updated: record['recorded_at']
      }
    end
  end
  
      def delete_product(url)
      records = load_database
      
      original_count = records.length
      records.reject! { |record| record['url'] == url }
      deleted_count = original_count - records.length
      
      if deleted_count > 0
        save_database(records)
        log("[DELETE] Deleted #{deleted_count} price records for: #{url}")
        { success: true, deleted_count: deleted_count, message: "Deleted #{deleted_count} price records" }
      else
        log("[DELETE] No records found for: #{url}")
        { success: false, message: "No records found for this URL" }
      end
    end
  
  private
  
      def setup_database
      FileUtils.mkdir_p(File.dirname(@db_path))
      
      unless File.exist?(@db_path)
        File.write(@db_path, JSON.generate([]))
      end
      
      log("[DB] Database setup complete")
    end
  
  def load_database
    return [] unless File.exist?(@db_path)
    
    begin
      JSON.parse(File.read(@db_path))
    rescue JSON::ParserError
      []
    end
  end
  
  def save_database(data)
    File.write(@db_path, JSON.generate(data, pretty: true))
    # Set restrictive permissions on database files
    File.chmod(0600, @db_path) if File.exist?(@db_path)
  end
  
  def attempt_scraping(url)
    log("[SCRAPE] Attempting to scrape: #{url}")
    log("[SCRAPE] Detecting store type...")
    
    begin
      html = fetch_page(url)
      
      if html
        log("[SCRAPE] Successfully fetched HTML content")
        result = parse_product_page(html, url)
        
        if result[:price] && result[:title]
          log("[SCRAPE] Success: #{result[:title]} - $#{result[:price]}")
          return {
            price: result[:price],
            title: result[:title],
            source: 'scraped',
            confidence: calculate_scrape_confidence(result),
            raw_data: result
          }
        else
          log("[SCRAPE] Failed: Could not extract price or title")
                log("[PARSE] Found prices: #{result[:all_prices]}") if result[:all_prices]
      log("[PARSE] Found title: #{result[:title]}")
          return { 
            price: nil, 
            source: 'scrape_failed',
            confidence: 0,
            error: "Could not extract price or title from page"
          }
        end
      else
        log("[SCRAPE] Failed: Could not fetch page")
        return { 
          price: nil, 
          source: 'fetch_failed', 
          confidence: 0,
          error: "Could not fetch page - may be blocked or URL invalid"
        }
      end
      
    rescue => e
      log("[SCRAPE] Error: #{e.message}")
      return { 
        price: nil, 
        source: 'scrape_error', 
        confidence: 0,
        error: e.message
      }
    end
  end
  
  def validate_price(scraped_result, user_price, url)
    log("[VALIDATE] Comparing scraped vs user reported prices")
    
    scraped_price = scraped_result[:price]
    
    # If scraping completely failed, use user price
    if !scraped_price
      log("[VALIDATE] Using user price (scraping failed)")
      return {
        price: user_price,
        title: scraped_result[:title] || extract_title_from_url(url),
        source: 'user_reported',
        confidence: 70, # User reported prices are pretty reliable
        needs_user_input: false
      }
    end
    
    # Compare scraped price vs user price
    price_diff_percent = ((scraped_price - user_price).abs / user_price * 100).round(1)
    
    log("[VALIDATE] Scraped: $#{scraped_price}, User: $#{user_price}, Diff: #{price_diff_percent}%")
    
    case price_diff_percent
    when 0..5  # Very close - probably accurate
      log("[VALIDATE] Prices match closely, using scraped price")
      return scraped_result.merge({
        confidence: 95,
        user_validation: "confirmed"
      })
      
    when 5..20  # Somewhat different - could be sale price vs regular
      log("[VALIDATE] Moderate difference, using average")
      average_price = ((scraped_price + user_price) / 2).round(2)
      return {
        price: average_price,
        title: scraped_result[:title],
        source: 'hybrid_average',
        confidence: 75,
        suggestion: "Scraped $#{scraped_price}, you reported $#{user_price}. Using average."
      }
      
    when 20..50  # Big difference - probably wrong scraping
      log("[VALIDATE] Large difference, favoring user price")
      return {
        price: user_price,
        title: scraped_result[:title],
        source: 'user_corrected',
        confidence: 65,
        suggestion: "Scraped price ($#{scraped_price}) seems off. Using your price."
      }
      
    else  # Huge difference - definitely wrong scraping
      log("[VALIDATE] Huge difference, using user price only")
      return {
        price: user_price,
        title: scraped_result[:title],
        source: 'user_override',
        confidence: 60,
        suggestion: "Scraped price ($#{scraped_price}) is very different from yours. Using your price.",
        needs_user_input: false
      }
    end
  end
  
  def fetch_page(url)
    # Amazon-specific headers to avoid detection
    store = detect_store(url)
    
    headers = case store
    when 'amazon'
      {
        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language' => 'en-US,en;q=0.9',
        'Accept-Encoding' => 'gzip, deflate, br',
        'Connection' => 'keep-alive',
        'Upgrade-Insecure-Requests' => '1',
        'Sec-Fetch-Dest' => 'document',
        'Sec-Fetch-Mode' => 'navigate',
        'Sec-Fetch-Site' => 'none',
        'Sec-Fetch-User' => '?1',
        'Cache-Control' => 'max-age=0',
        'DNT' => '1'
      }
    else
      {
        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
        'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language' => 'en-US,en;q=0.5',
        'Accept-Encoding' => 'gzip, deflate, br',
        'Connection' => 'keep-alive',
        'Upgrade-Insecure-Requests' => '1',
        'Sec-Fetch-Dest' => 'document',
        'Sec-Fetch-Mode' => 'navigate',
        'Sec-Fetch-Site' => 'none'
      }
    end
    
    # Performance optimizations
    options = {
      headers: headers,
      timeout: 10,  # Reduced from 15 to 10 seconds
      follow_redirects: true,
      verify: false,  # Skip SSL verification for speed
      ssl_version: :TLSv1_2
    }
    
    # Retry logic for better reliability
    max_retries = 2
    retry_count = 0
    
    begin
      log("[FETCH] Attempt #{retry_count + 1} for: #{url}")
      response = HTTParty.get(url, options)
      log("[FETCH] Response code: #{response.code}")
      
      if response.code == 200
        log("[FETCH] Successfully fetched page (#{response.body.length} characters)")
        response.body
      elsif response.code == 429  # Rate limited
        if retry_count < max_retries
          retry_count += 1
          log("[FETCH] Rate limited, retrying in 2 seconds...")
          sleep 2
          raise "Rate limited, retrying..."
        else
          log("[FETCH] Rate limited after #{max_retries} attempts")
          nil
        end
      else
        log("[FETCH] HTTP Error: #{response.code}")
        nil
      end
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      if retry_count < max_retries
        retry_count += 1
        log("[FETCH] Timeout, retrying in 1 second...")
        sleep 1
        retry
      else
        log("[FETCH] Timeout after #{max_retries} attempts: #{e.message}")
        nil
      end
    rescue => e
      if e.message.include?("Rate limited") && retry_count < max_retries
        retry_count += 1
        retry
      else
        log("[FETCH] Error: #{e.message}")
        nil
      end
    end
  end
  
  def parse_product_page(html, url)
    doc = Nokogiri::HTML(html)
    store = detect_store(url)
    
    log("[PARSE] Parsing #{store} page")
    log("[PARSE] HTML document size: #{html.length} characters")
    
    # Optimize parsing for large pages
    if html.length > 500000  # 500KB
      log("[PARSE] Large page detected, using optimized parsing")
      # For very large pages, focus on specific sections
      doc = Nokogiri::HTML(html.slice(0, 200000))  # Only parse first 200KB
    end
    
    # Extract title first
    title = extract_title(doc, store)
    log("[PARSE] Found title: #{title}")
    
    # Extract prices using improved method
    log("[PARSE] Starting price extraction...")
    all_prices = extract_all_prices_improved(doc, store)
    log("[PARSE] Found prices: #{all_prices}")
    
    # Use smart price selection
    log("[PARSE] Starting smart price selection...")
    selected_price = smart_price_selection(all_prices, store)
    log("[PARSE] Selected price: #{selected_price}")
    
    {
      title: title,
      price: selected_price,
      all_prices: all_prices,
      store: store
    }
  end
  
  def detect_store(url)
    uri = URI.parse(url)
    domain = uri.host.downcase
    
    store = case domain
    when /amazon\./
      'amazon'
    when /ebay\./
      'ebay'  
    when /bestbuy\./
      'bestbuy'
    else
      'unknown'
    end
    
    log("[STORE] Detected store: #{store} from domain: #{domain}")
    store
  end
  
  def extract_title(doc, store)
    selectors = case store
    when 'ebay'
      [
        'h1[data-testid="x-item-title-label"]',
        'h1#x-title-label-lbl', 
        'h1.x-item-title-label',
        'h1#it-ttl',
        'span#vi-lkhdr-itmTitl',
        'h1'
      ]
    when 'amazon'
      [
        '#productTitle',
        'h1.a-size-large',
        'h1#title',
        'h1.a-size-large.a-color-base',
        'span#productTitle',
        'h1[data-automation-id="product-title"]',
        'h1'
      ]
    else
      ['h1', 'title']
    end
    
    selectors.each do |selector|
      elements = doc.css(selector)
      next if elements.empty?
      
      text = elements.first.text.strip
      next if text.empty? || text.length < 5
      
      # Clean up title
      cleaned = text.gsub(/\s+/, ' ')
                   .gsub(/\s*\|\s*(eBay|Amazon|Best Buy).*$/i, '')
                   .gsub(/Details about\s*/i, '')
                   .strip
      
      return cleaned if cleaned.length > 5
    end
    
    "Unknown Product"
  end
  
  def extract_all_prices_improved(doc, store)
    prices = []
    
    case store
    when 'ebay'
      ebay_sale_selectors = [
        'span[data-testid="price-current"]',
        'span.u-flL.condText span.notranslate',
        'span[id*="sale"] span.notranslate',
        'span[class*="sale"] span.notranslate',
        'span[class*="current"] span.notranslate'
      ]
      
      ebay_regular_selectors = [
        'span.notranslate[data-testid*="price"]',
        'span[data-testid="price"]',
        'span#mm-saleDscPrc',
        'span#prcIsum',
        'span.notranslate',
        'span[class*="price"]',
        'div[data-testid*="price"] span'
      ]
      
      log("[PARSE] Looking for eBay prices...")
      ebay_sale_selectors.each do |selector|
        doc.css(selector).each do |element|
          text = element.text.strip
          price = extract_price_number(text)
          if price
            log("[PARSE] Found eBay price: $#{price}")
            prices << { price: price, type: 'sale', selector: selector }
          end
        end
      end
      
      ebay_regular_selectors.each do |selector|
        doc.css(selector).each do |element|
          text = element.text.strip
          price = extract_price_number(text)
          if price
            log("[PARSE] Found eBay price: $#{price}")
            prices << { price: price, type: 'regular', selector: selector }
          end
        end
      end
      
    when 'amazon'
      amazon_selectors = [
        'span.a-price-whole',
        'span.a-offscreen',
        'span#priceblock_dealprice',
        'span#priceblock_price',
        'span[data-a-color="price"] span.a-offscreen',
        'span[data-a-color="price"] span.a-price-whole',
        'span[class*="price"]'
      ]
      
      log("[PARSE] Looking for Amazon prices...")
      amazon_selectors.each do |selector|
        doc.css(selector).each do |element|
          text = element.text.strip
          price = extract_price_number(text)
          if price
            log("[PARSE] Found Amazon price: $#{price}")
            prices << { price: price, type: 'regular', selector: selector }
          end
        end
      end
      
      if prices.empty?
        log("[PARSE] No Amazon prices found with standard selectors")
      end
      
    when 'bestbuy'
      bestbuy_selectors = [
        '[data-testid="large-customer-price"]',
        '[data-testid="customer-price"]',
        '.customer-price',
        'span[class*="customer-price"]',
        'span[data-testid="price-value"]',
        'span.priceView-customer-price',
        'span.priceView-layout-large',
        'span[class*="price"]',
        'div[data-testid="price"] span',
        'span[data-automation-id="price"]',
        'span.price'
      ]
      
      log("[PARSE] Looking for Best Buy prices...")
      bestbuy_selectors.each do |selector|
        doc.css(selector).each do |element|
          text = element.text.strip
          price = extract_price_number(text)
          if price
            log("[PARSE] Found Best Buy price: $#{price}")
            prices << { price: price, type: 'regular', selector: selector }
          end
        end
      end
      
      if prices.empty?
        log("[PARSE] No Best Buy prices found with standard selectors")
      end
    end
    
    # Remove duplicates and return just the price values for now
    unique_prices = prices.map { |p| p[:price] }.uniq.sort
    
    log("[PARSE] All found prices: #{unique_prices}")
    
    unique_prices
  end
  
  def extract_price_number(text)
    cleaned_text = text.gsub(/[^\d,.]/, ' ').strip
    
    # Matches prices like $1,299.99, $59.99, $1,299 (with or without cents)
    price_match = cleaned_text.match(/(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)/)
    if price_match
      price_str = price_match[1].gsub(',', '')
      price_float = price_str.to_f
      
      # Sanity check: reasonable price range to filter out garbage
      if price_float > 0 && price_float < 50000
        log("[PARSE] Extracted price: $#{price_float} from '#{text}'")
        return price_float
      end
    end
    
    log("[PARSE] Could not extract price from: '#{text}'")
    nil
  end
  
  def smart_price_selection(all_prices, store)
    return nil if all_prices.empty?
    
    # Remove obvious outliers (shipping costs, etc.)
    reasonable_prices = all_prices.select { |p| p >= 5 && p <= 10000 }
    return all_prices.first if reasonable_prices.empty?
    
    log("[PRICE_SELECT] Reasonable prices found: #{reasonable_prices.sort}")
    
    # For different stores, use different strategies
    case store
    when 'ebay'
      select_ebay_price(reasonable_prices)
      
    when 'amazon'
      select_amazon_price(reasonable_prices)
    when 'bestbuy'
      select_bestbuy_price(reasonable_prices)
      
    else
      sorted = reasonable_prices.sort
      sorted[sorted.length / 2]
    end
  end
  
  def select_ebay_price(prices)
    return nil if prices.empty?
    
    log("[EBAY_PRICE] Analyzing #{prices.length} prices")
    
    all_counts = prices.group_by(&:itself).transform_values(&:count)
    most_common = all_counts.max_by { |price, count| count }
    
    if most_common && most_common[1] > 1
      log("[EBAY_PRICE] Selected most common price: $#{most_common[0]} (appears #{most_common[1]} times)")
      return most_common[0]
    end
    
    # eBay often shows financing options (e.g., $37.52/mo) alongside main price ($109.98)
    # Selecting highest price ensures we get the full product price, not financing
    sorted = prices.sort
    highest = sorted.last
    log("[EBAY_PRICE] Selected highest price: $#{highest} (main product price)")
    return highest
  end
  
  def select_bestbuy_price(prices)
    return nil if prices.empty?
    
    log("[BESTBUY_PRICE] Analyzing #{prices.length} prices")
    
    all_counts = prices.group_by(&:itself).transform_values(&:count)
    most_common = all_counts.max_by { |price, count| count }
    
    if most_common && most_common[1] > 1
      log("[BESTBUY_PRICE] Selected most common price: $#{most_common[0]} (appears #{most_common[1]} times)")
      return most_common[0]
    end
    
    # Best Buy shows financing options alongside main price
    # Highest price is typically the full product price, not monthly payments
    sorted = prices.sort
    highest = sorted.last
    log("[BESTBUY_PRICE] Selected highest price: $#{highest} (main product price)")
    return highest
  end
  
  def select_amazon_price(prices)
    return nil if prices.empty?
    
    log("[AMAZON_PRICE] Analyzing #{prices.length} prices")
    
    # Amazon often extracts partial prices like $59.0 instead of $59.99
    # This filters for complete prices with exactly 2 decimal places
    prices_with_cents = prices.select { |p| p.to_s.include?('.') && p.to_s.split('.')[1]&.length == 2 }
    if prices_with_cents.any?
      cent_counts = prices_with_cents.group_by(&:itself).transform_values(&:count)
      most_common = cent_counts.max_by { |price, count| count }
      
      if most_common && most_common[1] > 1
        log("[AMAZON_PRICE] Selected most common complete price: $#{most_common[0]} (appears #{most_common[1]} times)")
        return most_common[0]
      end
    end
    
    all_counts = prices.group_by(&:itself).transform_values(&:count)
    most_common = all_counts.max_by { |price, count| count }
    
    if most_common && most_common[1] > 1
      log("[AMAZON_PRICE] Selected most common price: $#{most_common[0]} (appears #{most_common[1]} times)")
      return most_common[0]
    end
    
    sorted = prices.sort
    median = sorted[sorted.length / 2]
    log("[AMAZON_PRICE] Selected median price: $#{median}")
    return median
  end
  
  def calculate_scrape_confidence(result)
    confidence = 50
    
    # Higher confidence if we found a meaningful title (indicates successful parsing)
    confidence += 20 if result[:title] && result[:title].length > 10
    
    price = result[:price]
    # Higher confidence for prices in typical e-commerce range
    confidence += 15 if price && price >= 10 && price <= 5000
    
    # Lower confidence if too many prices found (indicates messy/scraped page)
    if result[:all_prices] && result[:all_prices].length > 20
      confidence -= 10
    end
    
    [confidence, 95].min
  end
  
  def save_price_record(url, price_data)
    records = load_database
    
    new_record = {
      'url' => url,
      'title' => price_data[:title],
      'price' => price_data[:price],
      'source' => price_data[:source],
      'confidence' => price_data[:confidence],
      'recorded_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
    }
    
    records << new_record
    save_database(records)
    
    log("[DB] Saved price record: $#{price_data[:price]} (#{price_data[:source]})")
  end
  
  def calculate_trend(history)
    return "insufficient_data" if history.length < 3
    
    # Compare recent 5 prices vs older 5 prices to determine trend
    recent = history.first(5).map { |h| h[:price] }.compact
    older = history.last(5).map { |h| h[:price] }.compact
    
    return "insufficient_data" if recent.empty? || older.empty?
    
    recent_avg = recent.sum.to_f / recent.length
    older_avg = older.sum.to_f / older.length
    
    change_percent = ((recent_avg - older_avg) / older_avg * 100).round(1)
    
    # Classify trend based on percentage change
    case change_percent
    when -Float::INFINITY..-10
      "decreasing"
    when -10..10
      "stable"
    when 10..Float::INFINITY
      "increasing"
    end
  end
  
  def extract_title_from_url(url)
    uri = URI.parse(url)
    path_parts = uri.path.split('/')
    
    product_part = path_parts.find { |part| part.length > 3 && !part.match(/^\d+$/) }
    
    if product_part
      product_part.gsub(/[-_]/, ' ').gsub(/\b\w/) { |m| m.upcase }
    else
      "Product from #{uri.host}"
    end
  end
end