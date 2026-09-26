// GoogleProjectID é injetado pelo environment do Dataform Cloud:
//   release branch → shopper-performance-qa
//   master  branch → shopper-performance-prod
const TARGET_PROJECT = dataform.projectConfig.defaultProject;

const isQA   = TARGET_PROJECT === "shopper-performance-qa";
const isProd = TARGET_PROJECT === "shopper-performance-prod";

const DATALAKE_PROJECT = isQA ? "shopper-datalakehouse-qa" : "shopper-datalakehouse-prod";
const DATASET          = "Ranking_Performance";

module.exports = { TARGET_PROJECT, DATALAKE_PROJECT, DATASET, isQA, isProd };
