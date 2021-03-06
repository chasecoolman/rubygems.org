require 'zlib'

class FastlyLogProcessor
  class AlreadyProcessedError < ::StandardError; end

  attr_accessor :bucket, :key

  def initialize(bucket, key)
    @bucket = bucket
    @key = key
  end

  def perform
    counts = download_counts

    # Temporary feature flag while we roll out fastly log processing
    if ENV['FASTLY_LOG_PROCESSOR_ENABLED'] != 'true'
      # Just log & exit w/out updating stats
      Delayed::Worker.logger.info "Processed Fastly log counts: #{counts.inspect}"
      StatsD.increment('fastly_log_processor.processed')
      return
    end

    # Check if this log has already been processed by another job
    unless Redis.current.setnx(redis_key, 'processing')
      raise FastlyLogProcessor::AlreadyProcessedError, "Already processed bucket: #{bucket} key: #{key}"
    end

    # Set a short expiry while updating
    Redis.current.expire(redis_key, 2.minutes)

    Download.bulk_update(munge_for_bulk_update(counts))

    Redis.current.set(redis_key, 'processed')
    Redis.current.expire(redis_key, 30.days)
  end

  # Takes an enumerator of log lines and returns a hash of download counts
  # E.g.
  #   {
  #     'rails-4.0.0' => 25,
  #     'rails-4.2.0' => 50
  #   }
  def download_counts(enumerator = log_lines)
    enumerator.each_with_object(Hash.new(0)) do |log_line, accum|
      path, response_code = log_line.split[10, 2]
      # Only count successful downloads
      # NB: we consider a 304 response a download attempt
      if [200, 304].include?(response_code.to_i) && (match = path.match %r{/gems/(?<path>.+)\.gem})
        accum[match[:path]] += 1
      end

      accum
    end
  end

  # Takes a hash of download counts and turns it into an array of arrays for
  # Download.bulk_update. E.g.:
  #   [
  #     ['rails', 'rails-4.0.0', 25 ],
  #     ['rails', 'rails-4.2.0', 50 ]
  #   ]
  def munge_for_bulk_update(download_counts)
    download_counts.map do |path, count|
      name = Version.rubygem_name_for(path)
      # Skip downloads that don't have a version in redis
      name ? [name, path, count] : nil
    end.compact
  end

  def log_lines
    s3_body.each_line
  end

  def s3_body
    # TODO: Are rubygems' fastly logs gzipped?
    io = Aws::S3::Object.new(bucket_name: bucket, key: key).get.body
    io = Zlib::GzipReader.wrap(io) if key.end_with?('.gz')
    io
  end

  def redis_key
    "fastly-log:#{bucket}:#{key}"
  end
end
