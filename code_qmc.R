

# PRELIMINARY ##################################################################

# Function to read in all required packages in one go:
load_packages <- function(x) {
  for(i in x) {
    if(!require(i, character.only = TRUE)) {
      install.packages(i, dependencies = TRUE)
      library(i, character.only = TRUE)
    }
  }
}

theme_AP <- function() {
  theme_bw() +
    theme(panel.grid.major = element_blank(),
          panel.grid.minor = element_blank(),
          legend.background = element_rect(fill = "transparent",
                                           color = NA),
          legend.margin=margin(0, 0, 0, 0),
          legend.box.margin=margin(-7,-7,-7,-7),
          legend.key = element_rect(fill = "transparent",
                                    color = NA),
          legend.title = element_text(size = 9),
          legend.text = element_text(size = 8),
          strip.background = element_rect(fill = "white"),
          axis.title.x = element_text(size = 9),
          axis.title.y = element_text(size = 9))
}

# Load the packages
load_packages(c("sensobol", "data.table", "tidyverse", "parallel",
               "scales", "doParallel", "benchmarkme",
               "cowplot", "wesanderson", "logitnorm"))

# DEFINE FUNCTIONS #############################################################

# Define function to random sample distributions
sample_distributions_PDF <- list(
  "uniform" = function(x) dunif(x, 0, 1),
  "normal" = function(x) dnorm(x, 0.5, 0.15),
  "beta" = function(x) dbeta(x, 8, 2),
  "beta2" = function(x) dbeta(x, 2, 8),
  "beta3" = function(x) dbeta(x, 2, 0.8),
  "beta4" = function(x) dbeta(x, 0.8, 2),
  "logitnormal" = function(x) dlogitnorm(x, 0, 3.16)
)

# Quantile function
sample_distributions <- list(
  "uniform" = function(x) qunif(x, -1, 1),
  "normal" = function(x) qnorm(x, 0, 0.3),
  "beta" = function(x) qbeta(x, 8, 2),
  "beta2" = function(x) qbeta(x, 2, 8),
  "beta3" = function(x) qbeta(x, 2, 0.8),
  "beta4" = function(x) qbeta(x, 0.8, 2),
  "logitnormal" = function(x) qlogitnorm(x, 0, 3.16)
)

random_distributions <- function(mat, phi, epsilon) {
  names_ff <- names(sample_distributions)
  if(!phi == length(names_ff) + 1) {
    out <- sample_distributions[[names_ff[phi]]](mat)
  } else {
    set.seed(epsilon)
    temp <- sample(names_ff, ncol(mat), replace = TRUE)
    out <- sapply(seq_along(temp), function(x) sample_distributions[[temp[x]]](mat[, x]))
  }
  return(out)
}

# Define metafunction ---------------------------
meta_fun <- function(data, epsilon, n) {

  # Define list of functions included in metafunction
  function_list <- list(
    Linear = function(x) x,
    Quadratic = function(x) x ^ 2,
    Cubic = function(x) x ^ 3,
    Exponential = function(x) exp(1) ^ x / (exp(1) - 1),
    Periodic = function(x) sin(2 * pi * x) / 2,
    Discontinuous = function(x) ifelse(x > 0.5, 1, 0),
    Non.monotonic = function(x) 4 * (x - 0.5) ^ 2,
    Inverse = function(x) (10 - 1 / 1.1) ^ -1 * (x + 0.1) ^ - 1,
    No.effect = function(x) x * 0,
    Trigonometric = function(x) cos(x),
    Piecewise.large = function(x) ((-1) ^ as.integer(4 * x) * (0.125 - (x %% 0.25)) + 0.125),
    Piecewise.small = function(x) ((-1) ^ as.integer(32 * x) * (0.03125 - 2 * (x %% 0.03125)) + 0.03125) / 2,
    Oscillation = function(x) x ^ 2 - 0.2 * cos(7 * pi * x)
  )

  # Sample list of functions
  set.seed(epsilon)
  all_functions <- sample(names(function_list), ncol(data), replace = TRUE)

  # Compute model output first order effects
  mat.y <- sapply(seq_along(all_functions), function(x)
    function_list[[all_functions[x]]](data[, x]))

  # Compute first-order effects
  y1 <- Rfast::rowsums(mat.y)

  if (n >= 2) { # Activate interactions

    # Define matrix with all possible interactions up to the n-th order
    interactions <- lapply(2:n, function(x) RcppAlgos::comboGeneral(1:n, x, nThreads = 4))

    out <- lapply(1:length(interactions), function(x) {
      lapply(1:nrow(interactions[[x]]), function(y) {
        Rfast::rowprods(mat.y[, interactions[[x]][y, ]])
      })
    })

    y2 <- lapply(out, function(x) do.call(cbind, x)) %>%
      do.call(cbind, .) %>%
      Rfast::rowsums(.)

  } else {

    y2 <- 0
  }

  y <- y1 + y2

  return(y)
}

# Add stopping rule for precaution --------------
model <- function(data, epsilon, n) {

  k <- ncol(data)

  if (n > k) {

    stop("level_interactions should be smaller or equal than \n
         the number of parameters")
  }

  y <- meta_fun(data = data, epsilon = epsilon, n = n)

  return(y)
}

# Finalize model --------------------------------
model_fun <- function(k, epsilon, phi, model.runs, n, type, matrices) {

  params <- paste("X", 1:k, sep = "")
  set.seed(epsilon)
  mat <- sobol_matrices(N = model.runs, params = params, type = type,
                        matrices = matrices)
  mat <- random_distributions(mat = mat, phi = phi, epsilon = epsilon)
  y <- model(data = mat, epsilon = epsilon, n = n)
  indices <- sobol_indices(Y = y, N = model.runs, params = params, matrices = matrices,
                           first = "azzini", total = "azzini")
  model.output <- mean(y[1:model.runs])

  output <- list(model.output, indices)
  names(output) <- c("output", "indices")

  return(output)
}

# DEFINE SETTINGS #############################################################

params <- c("k", "epsilon", "n", "phi")
N <- 2^10
matrices <- "A"
max.k <- 10 # maximum number of explored inputs

# Define an increasing sample size --------------
exponents <- 7:14
sample.sizes <- 2^exponents

# CREATE SAMPLE MATRIX ########################################################

# Creation of sample matrix ---------------------
mat <- sobol_matrices(N = N, params = params, matrices = matrices)

# Transformation to appropriate distributions ---
mat[, "k"] <- floor(mat[, "k"] * (max.k - 2 + 1) + 2)
mat[, "epsilon"] <- floor(mat[, "epsilon"] * (N - 1 + 1) + 1)
mat[, "phi"] <- floor(mat[, "phi"] * ((length(sample_distributions) + 1) - 1 + 1) + 1)
mat[, "n"] <- floor(mat[, "n"] * (max.k - 1 + 1) + 1)

# Constrain n as a function of k
mat[, "n"] <- ifelse(mat[, "n"] > mat[, "k"], mat[, "k"], mat[, "n"])

# Replicate the sample matrix for each sample size
n.times <- length(sample.sizes)
mat <- matrix(rep(t(mat), n.times), ncol = ncol(mat), byrow = TRUE)
model.runs <- rep(sample.sizes, each = N)

mat <- cbind(mat, model.runs)
colnames(mat) <- c(params, "model.runs")
mat <- data.table(mat)
sampling.methods <- c("R", "QRN", "LHS")

# Replicate matrix for each sampling method -----
final.mat <- mat[rep(mat[, .I], length(sampling.methods))]
final.mat <- final.mat[, sample.method:= rep(sampling.methods, each = N * n.times)]

# RUN SIMULATIONS #############################################################

# Define parallel computing ---------------------
matrices <- c("A", "B", "AB", "BA")
n_cores <- detectCores() * 0.75
cl <- makeCluster(n_cores)
registerDoParallel(cl)

# Compute ---------------------------------------
y <- foreach(i=1:nrow(final.mat),
             .packages = c("Rfast", "sensobol", "dplyr", "RcppAlgos",
                           "logitnorm")) %dopar%
  {
    model_fun(k = final.mat[[i, "k"]],
              epsilon = final.mat[[i, "epsilon"]],
              n = final.mat[[i, "n"]],
              phi = final.mat[[i, "phi"]],
              model.runs = final.mat[[i, "model.runs"]],
              type = final.mat[[i, "sample.method"]],
              matrices = matrices)
  }

# Stop parallel cluster -------------------------
stopCluster(cl)

# ARRANGE RESULTS ##############################################################

dt.output <- do.call("c", lapply(y, function(x) x$output))
dt.indices <- lapply(y, function(x) x$indices)
sum.si <- do.call("c", lapply(dt.indices, function(x) x$si.sum))
mean.dimension <- lapply(dt.indices, function(x) x$results %>%
                           .[sensitivity == "Ti"] %>%
                           .[, sum(original)]) %>%
  do.call("c", .)
kt <- lapply(dt.indices, function(x) x$results %>%
               .[sensitivity == "Ti"] %>%
               .[original > 0.05] %>%
               nrow(.)) %>%
  do.call("c", .)
dt.dimensions <- cbind(final.mat, sum.si, kt, mean.dimension)

dt.largest.sample <- dt.dimensions[model.runs == sample.sizes[length(sample.sizes)]]

# ---------------------

# Merge output with sample matrix ---------------

dt <- cbind(final.mat, dt.output)
dt.benchmark <- dt[model.runs == sample.sizes[length(sample.sizes)]]

dt.tmp <- split(dt, dt$model.runs) %>%
  lapply(., function(x) merge(x, dt.benchmark, by = c("k", "epsilon",
                                                      "sample.method", "n"))) %>%
  rbindlist(., idcol = "sample.size") %>%
  setnames(., c("dt.output.y", "dt.output.x"), c("y", "y.highest")) %>%
  .[, `:=` (model.runs.x = NULL, model.runs.y = NULL)] %>%
  .[, .(RMSE = sqrt(mean((y.highest - y)^2))), .(sample.size, sample.method)]

# CHECK N?? SIMULATIONS WITH SUM S_I < 0 ########################################

dt.largest.sample[, .(negative = sum.si < 0)] %>%
  .[, .N, negative]


hist(dt.largest.sample$mean.dimension, na.rm = TRUE)
# PLOT #########################################################################

plot.convergence <- dt.tmp %>%
  .[, sample.size:= as.numeric(sample.size)] %>%
  ggplot(., aes(sample.size, RMSE, color = sample.method, group = sample.method)) +
  geom_line() +
  scale_x_log10() +
  theme_AP() +
  labs(x = "N?? of model runs", y = "RMSE") +
  scale_color_discrete(name = "Sampling method") +
  theme(legend.position = c(0.7, 0.7))

plot.convergence

# Plot distribution of functions based on sum S_i
plot.histogram <- dt.largest.sample %>%
  ggplot(., aes(sum.si)) +
  geom_histogram(fill = "white", color = "black") +
  theme_AP() +
  scale_x_continuous(limits = c(0, 1)) +
  labs(x = "$\\sum_{i=1}^{k} S_i$",  y = "Counts") +
  theme(legend.position = c(0.35, 0.7))

plot.histogram

# Plot sum of S_i against k and colored by k_t
plot.scatter <- dt.largest.sample %>%
  ggplot(., aes(sum.si, kt, color = k)) +
  geom_point(size = 0.7) +
  scale_color_gradient(low = "red", high = "green",
                       name = "$k$") +
  theme_AP() +
  scale_x_continuous(limits = c(0, 1)) +
  theme(legend.position = "none") +
  labs(x = "$\\sum_{i=1}^{k} S_i$", y = "$k_t$")

legend <- get_legend(plot.scatter + theme(legend.position = "top"))

plot.scatter

plot.mean.dimensions <- dt.largest.sample %>%
  ggplot(., aes(mean.dimension, sum.si)) +
  geom_point(size = 0.6, alpha = 0.5) +
  labs(x = "$\\sum_{i=1}^k T_i$", y = "$\\sum_{i=1}^k S_i$") +
  theme_AP()

plot.mean.dimensions

bottom.plots <- plot_grid(plot.histogram, plot.scatter, plot.mean.dimensions,
                          ncol = 3, labels = "auto")

plot_grid(legend, bottom.plots, ncol = 1, rel_heights = c(0.2, 0.8))

# SESSION INFORMATION ##########################################################

sessionInfo()

## Return the machine CPU
cat("Machine:     "); print(get_cpu()$model_name)

## Return number of true cores
cat("Num cores:   "); print(detectCores(logical = FALSE))

## Return number of threads
cat("Num threads: "); print(detectCores(logical = FALSE))

########################## END SIMULATIONS #####################################
################################################################################


dt.largest.sample %>%
  ggplot(., aes(mean.dimension, sum.si)) +
  geom_point() +
  theme_AP()




N <- 2^14
params <- paste("X", 1:8, sep = "")
mat <- sobol_matrices(N = N, params = params)
y <- sobol_Fun(mat)
ind <- sobol_indices(N = N, Y = y, params = params)
ind$results[sensitivity == "Ti"][, sum(original)]



1.7 / 3

k <- 3
mean_fun <- 1 / (2^k - 1)

0.14 * 4
0.56 * 3

2 * mean_fun * 3
3 * mean_fun * 2

out <- 0
mean_fun <- 1 / (2^k - 1)

for (i in 1:k) {
  out <- out + i * choose(k,i) * mean_fun
}
out



