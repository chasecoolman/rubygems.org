require 'cgi'

class SqsWorker
  include Shoryuken::Worker

  shoryuken_options queue: ENV['SQS_QUEUE'], body_parser: :json, auto_delete: true

  def perform(_sqs_msg, body)
    s3_objects = body['Records'].map do |record|
      [
        record['s3']['bucket']['name'],
        CGI.unescape(record['s3']['object']['key'])
      ]
    end

    StatsD.increment('fastly_log_processor.s3_entry_fetched')

    ActiveRecord::Base.transaction do
      s3_objects.each do |bucket, key|
        StatsD.increment('fastly_log_processor.enqueued')
        Delayed::Job.enqueue FastlyLogProcessor.new(bucket, key), priority: PRIORITIES[:stats]
      end
    end
  end
end
