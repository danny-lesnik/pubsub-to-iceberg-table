project_id                   = "i-matrix-381811"
iceberg_bucket_name          = "lake"
spark_jobs_bucket_name       = "jobs"
spark_job_filename           = "../pyspark_job/pubsub.py"
pub_sub_lite_topic_name      = "spark-streaming"
dataproc_cluster_name        = "lake-dataproc"
region                       = "us-central1"
vpc_name                     = "test"
subnetwork                   = "us-central-subnet"
pubsub_lite_spark_file_name  = "gs://spark-lib/pubsublite/pubsublite-spark-sql-streaming-1.0.0-with-dependencies.jar"
