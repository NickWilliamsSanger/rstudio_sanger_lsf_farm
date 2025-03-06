#!/usr/bin/env bash
set -e # exit when any command fails

# code heavily inspired from:
#  - https://www.rocker-project.org/use/singularity/
#   - https://support.rstudio.com/hc/en-us/articles/200552316-Configuring-the-Server
# using dockerhub image converted to singularity:
#  - https://hub.docker.com/r/rocker/tidyverse/tags?page=1&ordering=last_updated

# HGI software documentation:
#  - https://confluence.sanger.ac.uk/display/HGI/Software+on+the+Farm

start_rserver() {

#####################
#####################
# as of June 24th 2021, the 3 official R versions and library paths supported by ISG are: 
# /software/R-3.6.1/bin/R
#   with lib path "/software/R-3.6.1/lib/R/library"
# and, 
# /software/R-4.0.3/bin/R
#   with lib path "/software/R-4.0.3/lib/R/library"
# and, 
# /software/R-4.1.0/bin/R
#   with lib path "/software/R-4.1.0/lib/R/library"
#####################
## Above was applicable to farm5 
#####################

# add latest singularity exec to PATH:
export PATH=/software/singularity/3.11.4/bin/:$PATH
    
# set .libPaths() for container R session:
if [ -z "$R_LIBS_USER" ]
then
    echo "R_LIBS_USER is empty"
    export CONTAINER_R_LIBS_USER=/software/R-$R_VERSION/lib/R/library
else
    echo "R_LIBS_USER is NOT empty"
    if [[ "$R_LIBS_USER" =~ ':'$ ]]; then
	echo "R_LIBS_USER has trailing colon: $R_LIBS_USER"
        export CONTAINER_R_LIBS_USER=${R_LIBS_USER}/software/R-$R_VERSION/lib/R/library
    else
	echo "R_LIBS_USER doesn't have trailing colon: $R_LIBS_USER"
	export CONTAINER_R_LIBS_USER=${R_LIBS_USER}:/software/R-$R_VERSION/lib/R/library
    fi   
fi
# if r lib path specified as input argument, prepend to container R_LIBS_USER
if [ ! -z "${CUSTOM_R_LIBPATH}" ]
  then
    export CONTAINER_R_LIBS_USER=${CUSTOM_R_LIBPATH}:${CONTAINER_R_LIBS_USER}
fi
export SINGULARITYENV_CONTAINER_R_LIBS_USER="${CONTAINER_R_LIBS_USER}"
echo "CONTAINER_R_LIBS_USER is set to $CONTAINER_R_LIBS_USER"

# Create temporary directory to be populated with directories to bind-mount in the container
# where writable file systems are necessary. Adjust path as appropriate for your computing environment.
workdir="$(mktemp -d)" # workdir=$(python -c 'import tempfile; print(tempfile.mkdtemp())')

mkdir -p -m 700 ${workdir}/run ${workdir}/tmp ${workdir}/var/lib/rstudio-server

# Set OMP_NUM_THREADS to prevent OpenBLAS (and any other OpenMP-enhanced
# libraries used by R) from spawning more threads than the number of processors
# allocated to the job.
#
# Set R_LIBS_USER to a path specific to rocker/rstudio to avoid conflicts with
# personal libraries from any R installation in the host environment

cat > ${workdir}/rsession.sh <<END
#!/bin/sh
export OMP_NUM_THREADS=$N_CPUS
export R_LIBS_USER=$CONTAINER_R_LIBS_USER
export http_proxy="wwwcache.sanger.ac.uk:3128"
export https_proxy="wwwcache.sanger.ac.uk:3128"

exec /usr/lib/rstudio-server/bin/rsession "\${@}"
END
#export R_LIBS_USER=${HOME}/R/rocker-rstudio/4.0

chmod +x ${workdir}/rsession.sh

# Do not suspend idle sessions:
# Alternative to setting session-timeout-minutes=0 in /etc/rstudio/rsession.conf
# https://github.com/rstudio/rstudio/blob/v1.4.1106/src/cpp/server/ServerSessionManager.cpp#L126
export SINGULARITYENV_RSTUDIO_SESSION_TIMEOUT=0

export SINGULARITYENV_USER=$(id -un)
export SINGULARITYENV_PASSWORD=$(openssl rand -base64 15)
HOST_IP=$(hostname -i)

# get free port for rstudio server:
read LOWERPORT UPPERPORT < /proc/sys/net/ipv4/ip_local_port_range
while :
do
        PORT="`shuf -i $LOWERPORT-$UPPERPORT -n 1`"
        ss -lpn | grep -q ":$PORT " || break
done

# bind chosen work directory as default rstudio session directory
# also bind Sanger farm /lustre, /software and /nfs 
# Bind host libraries and font configuration
declare -a BIND_MOUNTS=(
  "/usr/lib/x86_64-linux-gnu:/usr/lib/host:ro"
  "${workdir}/run:/run"
  "${workdir}/tmp:/tmp"
  "${workdir}/rsession.sh:/etc/rstudio/rsession.sh"
  "${workdir}/var/lib/rstudio-server:/var/lib/rstudio-server"
  "${SESSION_DIRECTORY}"
  "/software"
  "/lustre"
  "/nfs"
)
export SINGULARITY_BIND="$(printf "%s," "${BIND_MOUNTS[@]}")"

## remove argument to 'rserver' that fails on R 3.6.1 container:
if [ $R_VERSION = "3.6.1" ]; then
  export EXTRA_RSERVER_ARGUMENTS=""
else
  export EXTRA_RSERVER_ARGUMENTS="--auth-timeout-minutes=0" #--rsession-config-file=/etc/rstudio/rsession.conf 
fi
echo EXTRA_RSERVER_ARGUMENTS is set to $EXTRA_RSERVER_ARGUMENTS
## 


#export PORT=38820
#export SINGULARITYENV_PASSWORD=pa01
echo "temporary writable work directory for the singularity container is set to $workdir"
echo SESSION_DIRECTORY is set to $SESSION_DIRECTORY
echo SINGULARITY_BIND is set to $SINGULARITY_BIND

printf "\n*** Access Rstudio session with "
printf "R version $R_VERSION "
printf "***\n"
printf " - the Rstudio session is set to run in directory "
printf "$SESSION_DIRECTORY\n"
printf " - the R library path (check from R with command '.libPaths()') will include: "
echo "$CONTAINER_R_LIBS_USER"
printf "\n\nPlease note:\n"
printf " - if Rstudio fails to recover a session in that directory, either remove its session files (i.e any .rstudio, .config, and .local directories, as well as the .RData and .Rhistory), or choose a different \$SESSION_DIRECTORY with --dir_session (or -d)"
printf "\n - /software, /lustre and /nfs are mounted inside the container, so should be accessible from the Rstudio session."
printf "\n - in the Rstudio session, the home directory (~ or $HOME) will not be set to your /nfs home directory, but it will still be accessible as /nfs is mounted inside the container."
printf "\n\nIf not using Sanger VPN, first run tunnelling SSH command:\n"
printf "ssh -o \"ServerAliveInterval 60\" -o \"ServerAliveCountMax 1200\" -L $PORT:$HOST_NAME.internal.sanger.ac.uk:$PORT ${USER}@ssh.sanger.ac.uk\n\n"
printf "If using Sanger VPN, simply point web browser to\n"
printf "http://$HOST_IP:$PORT\n"
printf "  use username "
printf "$SINGULARITYENV_USER\n"
printf "  use password"
printf " $SINGULARITYENV_PASSWORD\n"

singularity exec \
	    --cleanenv \
	    --containall \
	    --home $SESSION_DIRECTORY \
	    --pwd $SESSION_DIRECTORY \
	    ${RSTUDIO_CONTAINER} \
	      /usr/lib/rstudio-server/bin/rserver \
	        --www-port ${PORT} \
	        --www-thread-pool-size=$(( N_CPUS * 2 )) \
	        --auth-none=0 \
	        --auth-pam-helper-path=/usr/local/bin/pam-helper \
	        --auth-stay-signed-in-days=30 \
	        --server-working-dir=$SESSION_DIRECTORY \
	        --rsession-ld-library-path=/usr/lib/host:$LD_LIBRARY_PATH \
	        --rsession-path=/etc/rstudio/rsession.sh \
	        --server-user $SINGULARITYENV_USER \
	        $EXTRA_RSERVER_ARGUMENTS

}


#########################
# The command line help #
#########################
display_help() {
    echo "Usage: $0 [options...]" >&2
    echo
    echo "  -d, --dir_session       (optional) path to startup/default directory for the Rstudio session"
    echo "                          - do not set to your home dir \$HOME as it may conflict with container settings"
    echo "                          - defaults to current directory \$PWD"
    echo "                          - e.g. \"/lustre/scratch123/hgi/projects/ukbb_scrna/pipelines/my_R_analysis\""
    echo "                          - if Rstudio fails to recover a session in that directory, either:" 
    echo "                              1) remove its session files (i.e any .rstudio, .config, .local, .RData, and .Rhistory)"
    echo "                              or 2) choose a different --dir_session directory free of any session files."
    echo "  -r, --r_version         (optional) R version: must be either \"4.1.0\" or \"4.0.3\" or \"3.6.1\""
    echo "                          - defaults to \"4.1.0\""
    echo "                          - contact HGI to add support for other R versions"
    echo "  -l, --r_lib_path        (optional) path to R library path. Must be compatible with --r_version" 
    echo "                          - the default session .libPaths() will include: "
    echo "                              - any path set in env variable \$R_LIBS_USER (if set)"
    echo "                              - ISG's main libpath \"/software/R-\${R_VERSION}/lib/R/library\""
    echo "                          - e.g. \"/software/teamxxx/gn5/R/x86_64-conda_cos6-linux-gnu/4.0.3\""
    echo "                          - check or edit manually with command .libPaths() from Rstudio session"
    echo "  -a, --dir_singularity   (optional) Directory where singularity image is stored/cached"
    echo "                          - defaults to \"/software/hgi/containers\""
    echo "  -i, --image_singularity filename of the singularity image"
    echo "                          - defaults to \"bionic-R_\${R_VERSION}-rstudio_1.4.sif\""
    echo "  -c, --cpus              (optional) max number of CPUs allowed for the Rstudio session"
    echo "                          - do not set higher than N cpus requested to LSF farm (bsub -n argument)"
    echo "  -h, --help              Display this help message "
    echo
    exit 1
}

################################
# process CLI arguments        #
################################
while :
do
    case "$1" in
      -h | --help)
          display_help
          exit 1 
          ;;
      -r | --r_version)
          export R_VERSION=$2  # as of June 24th 2021, 4.1.0, 4.0.3 and 3.6.1 were manually pulled from dockerhub to /software/hgi/containers/
          shift 2
          ;;
      -c | --cpus)
	  export N_CPUS=$2 # must match number of CPUs requested by bsub
          shift 2
          ;;
      -d | --dir_session)
	  export SESSION_DIRECTORY=$2
          shift 2
          ;;
      -l | --r_lib_path)
	  export CUSTOM_R_LIBPATH=$2
          shift 2
          ;;
      -a | --dir_singularity)
	  export SINGULARITY_CACHE_DIR=$2 #  /software/hgi/containers
          shift 2
          ;;
      -i | --image_singularity)
	  export IMAGE_SINGULARITY=$2 
          shift 2
          ;;
      --) # End of all options
          shift
          break
          ;;
      -*)
          echo "Error: Unknown option: $1" >&2
          display_help
          exit 1 
          ;;
      *)  # No more options
          break
          ;;
    esac
done

###################### 
# Check if parameter #
# is set to execute #
######################
case "$1" in
  help)
    display_help
    ;;
  *)
    # set default values if arguments not provided:
    export R_VERSION="${R_VERSION:-4.3.1}"  # as of June 24th 2021, 4.1.0, 4.0.3 and 3.6.1 were manually pulled from dockerhub to /software/hgi/containers/
    export CUSTOM_R_LIBPATH="${CUSTOM_R_LIBPATH:-}" # leave empty by default 
    export N_CPUS="${N_CPUS:-1}" # must match number of CPUs requested by bsub
    export SESSION_DIRECTORY="${SESSION_DIRECTORY:-$PWD}"
    export SINGULARITY_CACHE_DIR="${SINGULARITY_CACHE_DIR:-/software/team273/rstudio_sanger_lsf_farm_images}" #  /software/hgi/containers
    export IMAGE_SINGULARITY="${IMAGE_SINGULARITY:-jammy-R_$R_VERSION-rstudio_2023.12.1+402.sif}" 
    export RSTUDIO_CONTAINER=$SINGULARITY_CACHE_DIR/$IMAGE_SINGULARITY # rocker_tidyverse_$R_VERSION.simg
    # will default to $PWD if empty
    # will be used as both PWD and HOME at container exec 
    # will also be used as rstudio session directory
    echo
    echo N_CPUS set to $N_CPUS
    echo SESSION_DIRECTORY set to $SESSION_DIRECTORY
    echo R_VERSION set to $R_VERSION
    echo CUSTOM_R_LIBPATH set to $CUSTOM_R_LIBPATH
    echo SINGULARITY_CACHE_DIR set to $SINGULARITY_CACHE_DIR
    echo RSTUDIO_CONTAINER set to $RSTUDIO_CONTAINER

    #####################
    #####################
    # pre-run checks:
    # check supported R studio versions
    if [[ ! "$R_VERSION" =~ ^(4.3.1|4.4.0)$ ]]; then
      echo "Error: R version --r_version (or -r) must be set to 4.3.1"
      echo "       contact HGI to add support for other R versions"
      exit 1
    fi
    # check that Rstudio session directory is writable
    if [ ! -w "$SESSION_DIRECTORY" ]
      then
        echo "Error: SESSION_DIRECTORY does not exist or is not writable. Please choose a --dir_session (or -d) directory you have write access to."
        exit 1
    fi
    # checks Rstudio session directory is not set to $HOME (conflicts with container internal settings) 
    if [ "$SESSION_DIRECTORY" = "$HOME" ]
      then
        echo "Error: Rstudio session directory should not be set to your \$HOME directory ($HOME). Please choose a different --dir_session (or -d) directory you have write access to, e.g. -d /lustre/scratch_xxx/path_to_your_analysis_dir."
        exit 1
    fi
    # check that singularity image exists
    if [ ! -r "$SINGULARITY_CACHE_DIR" ]
      then
        echo "Error: singularity cache directory is not readable. Please choose a --dir_singularity (or -a) that contains the rstudio container, e.g. -a /software/hgi/containers"
        exit 1
    fi
    if [ ! -r "$RSTUDIO_CONTAINER" ]
      then
        echo "Error: singularity image not accessible at \"$RSTUDIO_CONTAINER\". Please speficy arguments --dir_singularity and --image_singularity. --dir_singularity should be a directory containing a --image_singularity image file"
        exit 1
    fi
    # check that custom R libpath directory exists, if specified as input argument
    if [ ! -z "${CUSTOM_R_LIBPATH}" ]
      then
        if [ ! -r "${CUSTOM_R_LIBPATH}" ]
          then
            echo "Error: custom library lib path is not readable. Please choose a --r_lib_path (or -l) directory that exists and contains R libraries."
            exit 1
        fi
    fi
    
    #####################
    #####################
    # start main script (which is supposed to run within bsub on Sanger LSF farm):
    start_rserver

    exit 0
    ;;
esac

