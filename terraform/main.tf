terraform {
 backend "gcs" {
   bucket  = "iceberg-terraform-state"
   prefix  = "terraform/state"
 }
}

resource "random_id" "bucket_prefix" {
  byte_length = 5
}


resource "google_storage_bucket" "lake_bucket" {
  name          = "${var.iceberg_bucket_name}-${random_id.bucket_prefix.hex}"
  force_destroy = true
  location      = "US"
  storage_class = "STANDARD"
  versioning {
    enabled = false
  }
}

resource "google_storage_bucket_object" "lakehouse" {
  name   = "datalake/"
  bucket = google_storage_bucket.lake_bucket.name
  content = "bla"
  depends_on = [
    google_storage_bucket.lake_bucket

  ]
}

resource "google_storage_bucket" "job_bucket" {
  name          = "${var.spark_jobs_bucket_name}-${random_id.bucket_prefix.hex}"
  force_destroy = true
  location      = "US"
  storage_class = "STANDARD"
  project = var.project_id
  versioning {
    enabled = false
  }
}

resource "google_storage_bucket_object" "postgres" {
  name   = var.postgres_file_name
  source = var.postgres_file_name
  bucket = google_storage_bucket.job_bucket.name
  depends_on = [
    google_storage_bucket.job_bucket

  ]
}

resource "google_storage_bucket_object" "iceberg_jar" {
  name   = var.iceberg_jar_file_name
  source = var.iceberg_jar_file_name
  bucket = google_storage_bucket.job_bucket.name
  depends_on = [
    google_storage_bucket.job_bucket

  ]
}


resource "google_storage_bucket_object" "sparj_job" {
  source   = var.spark_job_filename
  name = "jobs/pubsub.py"
  bucket = google_storage_bucket.job_bucket.name
  depends_on = [
    google_storage_bucket.job_bucket

  ]
}


resource "google_pubsub_lite_reservation" "pub_sub_lite_reservation" {
  name = "${var.pub_sub_lite_topic_name}-${random_id.bucket_prefix.hex}-reservation"
  throughput_capacity = 4
  region = var.region
}

resource "google_pubsub_lite_topic" "pub_sub_lite_topic" {
  name   = "${var.pub_sub_lite_topic_name}-${random_id.bucket_prefix.hex}-topic"
  region = var.region
  zone   = var.region

  partition_config {
    count = 1
  }

  retention_config {
    per_partition_bytes = 32212254720
  }

  reservation_config {
    throughput_reservation = google_pubsub_lite_reservation.pub_sub_lite_reservation.name
  }
}

resource "google_pubsub_lite_subscription" "pubsub_subscription" {
  name  = "${var.pub_sub_lite_topic_name}-${random_id.bucket_prefix.hex}-subscription"
  region = var.region
  zone   = var.region
  topic  = google_pubsub_lite_topic.pub_sub_lite_topic.name
  delivery_config {
    delivery_requirement = "DELIVER_IMMEDIATELY"
  }
}

resource "google_dataproc_metastore_service" "metastore" {
  service_id = "${var.dataproc_cluster_name}-${random_id.bucket_prefix.hex}-metastore"
  location   = var.region
  port       = 9083
  tier       = "DEVELOPER"
  network    = "projects/${var.project_id}/global/networks/${var.vpc_name}"

  hive_metastore_config {
    version = "3.1.2"
  }
}


resource "google_storage_bucket" "stage_bucket" {
  name          = "stage-${random_id.bucket_prefix.hex}"
  force_destroy = true
  project = var.project_id
  location      = "US"
  storage_class = "STANDARD"
  versioning {
    enabled = false
  }
}



resource "google_dataproc_cluster" "spark_cluster" {
    depends_on = [
      google_dataproc_metastore_service.metastore,
      google_storage_bucket.stage_bucket
    ]
    name   ="${var.dataproc_cluster_name}-${random_id.bucket_prefix.hex}-cluster"
    region =  var.region     

  cluster_config {

    gce_cluster_config {
      zone = "${var.region}-a"

      # One of the below to hook into a custom network / subnetwork
      # network    = "test"
      subnetwork = var.subnetwork

    }
    staging_bucket = google_storage_bucket.stage_bucket.name
        master_config {
      num_instances = 1
      machine_type  = "n1-standard-2"
      disk_config {
        boot_disk_type    = "pd-ssd"
        boot_disk_size_gb = 30
      }
    }

    worker_config {
      num_instances    = 2
      machine_type     =  "n1-standard-2"
      disk_config {
        boot_disk_size_gb = 30
        num_local_ssds    = 1
      }
      
    }

    preemptible_worker_config {
      num_instances = 0
    }

        software_config {
      image_version = "2.1.8-ubuntu20"
      override_properties = {
        "dataproc:dataproc.allow.zero.workers" = "true",
        "spark:spark.jars" = "https://jdbc.postgresql.org/download/postgresql-42.5.1.jar,https://search.maven.org/remotecontent?filepath=org/apache/iceberg/iceberg-spark-runtime-3.3_2.12/1.1.0/iceberg-spark-runtime-3.3_2.12-1.1.0.jar",
        "hive:hive.metastore.uris" = "${google_dataproc_metastore_service.metastore.endpoint_uri}",
        "hive:hive.metastore.warehouse.dir" = "${google_dataproc_metastore_service.metastore.artifact_gcs_uri}"
      }
    }
  }
}

resource "google_dataproc_job" "pyspark" {  
  region       = google_dataproc_cluster.spark_cluster.region
  force_delete = true
  placement {
    cluster_name = google_dataproc_cluster.spark_cluster.name
  }

  pyspark_config {
    main_python_file_uri = "gs://${google_storage_bucket.job_bucket.name}/${google_storage_bucket_object.sparj_job.name}"
       jar_file_uris = [
        "gs://${google_storage_bucket.job_bucket.name}/${google_storage_bucket_object.postgres.name}",
        var.pubsub_lite_spark_file_name,
        "gs://${google_storage_bucket.job_bucket.name}/${google_storage_bucket_object.iceberg_jar.name}",

        ]
        args = [
            "--lake_bucket=gs://${google_storage_bucket.lake_bucket.name}/${google_storage_bucket_object.lakehouse.name}",
            "--psub_subscript_id=${google_pubsub_lite_subscription.pubsub_subscription.id}",
            "--checkpoint_location=gs://${google_storage_bucket.job_bucket.name}/" 
 
        ]
    properties = {
      "spark.logConf" = "true"
    }
  }
}