#
# Server or Local
#
cat("RBot v0.1\n")

if (F) {
  setwd("C:/projects/rbot") # server
} else {
  setwd("D:/data/dev/rbot") # client
}

#
# parameters
#
sportname <- "Soccer"
loopcycle <- 5 * 60 # secs
dbfilename <-
  paste0("dbdata", format(Sys.time(), "%Y-%m-%dT%H-%M"), ".RData")
#  paste0("dbdata", format(Sys.time(), "%Y-%m-%dT%H-%M"), ".sqlite")

#
# packages
#
suppressMessages({
  #require(DBI, quietly = T)
  #require(RSQLite, quietly = T)
  require(dplyr, quietly = T)
  require(httr, quietly = T)
  require(RCurl, quietly = T)
  require(pinnacle.API, quietly = T)
})

#
# API functions
#
getAuthorization <-
  function (user = as.character(GetCredentials()$Value[1]),
            pwd = as.character(GetCredentials()$Value[2])) {
    credentials = paste(user, pwd, sep = ":")
    credentials.r = charToRaw(enc2utf8(credentials))
    return(paste0("Basic ", base64Encode(credentials.r, "character")))
  }

getSportID <-
  function(sportname) {
    sports <- GetSports(F)
    return(sports[, "SportID"][tolower(sports[, "SportName"]) %in% tolower(sportname)])
  }

getInrunningFast <-
  function(sportid) {
    url <- "https://api.pinnaclesports.com/v1/inrunning"
    r <- GET(
      url,
      add_headers(Authorization = getAuthorization(),
                  "Content-Type" = "application/json")
    )
    res <-
      jsonlite::fromJSON(content(r, type = "text"), simplifyVector = FALSE)
    inrunningState <- JSONtoDF(res)
    names(inrunningState)[1:2] = c('SportID', 'LeagueID')
    if (length(names(inrunningState)) > 2)
      names(inrunningState)[3] = c('EventID')
    inrunningState[inrunningState[, 1] == sportid, ]
    return(inrunningState)
  }

getOddsFast <-
  function(sportid, since = NULL) {
    url <- "https://api.pinnaclesports.com/v1/odds"
    r <- GET(
      url,
      add_headers(Authorization = getAuthorization(),
                  "Content-Type" = "application/json"),
      query = list(sportId = sportid,
                   since = since)
    )
    return(jsonlite::fromJSON(content(r, type = "text"), simplifyVector = F))
  }

getFixturesFast <-
  function(sportid,
           leagueids,
           since = NULL,
           islive = 0) {
    url <- "https://api.pinnaclesports.com/v1/fixtures"
    r <- GET(
      url,
      add_headers(Authorization = getAuthorization(),
                  "Content-Type" = "application/json"),
      query = list(
        sportId = sportid,
        leagueids = paste(leagueids, collapse = ','),
        since = since,
        isLive = islive * 1
      )
    )
    res <-  jsonlite::fromJSON(content(r, type = "text"))
    out <- cbind(res$sportId,
                 res$last,
                 do.call(
                   bind_rows,
                   Map(
                     function(id, events)
                       data.frame(idEvent = id, events) ,
                     res$league$id,
                     res$league$events
                   )
                 ))
    colnames(out)[1:11] <- c(
      "SportID",
      "Last",
      "LeagueID",
      "EventID",
      "StartTime",
      "HomeTeamName",
      "AwayTeamName",
      "RotationNumber",
      "LiveStatus",
      "Status",
      "ParlayStatus"
    )
    return(out)
  }

removeNullFromList <-
  function(x) {
    #x <- x[!(sapply(x, is.null))] # remove NULL elements from list on top level
    x[sapply(x, is.null)] <- NA # replace NULL elements with NA
    lapply(x, function(x)
      # apply recursively
      if (is.list(x))
        removeNullFromList(x)
      else
        x)
  }

#
# init
#

# in-memory db
#con <- dbConnect(RSQLite::SQLite(), ":memory:")

# pinnacle api
load("up.RData")
SetCredentials(user, pwd)
AcceptTermsAndConditions(accepted = T)
sportID <- getSportID(sportname)
sinceTimeOdds <- NULL # api last get time
sinceTimeFixtures <- NULL # fixtures last get time
ticksDF <- NULL # tick data

#
# loop until user break
#
loopcounter <- 0
while (T) {
  cycletime <-
    Sys.time() + loopcycle # save time of starting next cycle
  
  tryCatch({
    #
    # read api data
    #
    #oddsData <- suppressMessages(showOddsDF("Soccer"))
    # filter api data
    #oddsFiltered <- oddsData %>%
    #  # Only Period "0" , the main period
    #  filter(PeriodNumber == 0) %>%
    #  # No Live Games
    #  filter(LiveStatus != 1) %>%
    #  # No Corners
    #  filter(. , !grepl("Corner", HomeTeamName))
    
    # odds and sincetime
    sportData <-
      suppressMessages(getOddsFast(sportID, sinceTimeOdds))
    #sinceTimeOdds <- sportData$last
    
    # leagues
    leagues <- GetLeaguesByID(sportID, force = T)
    leagues <- leagues[leagues$LinesAvailable == "1",]
    # attach league names
    sportData$leagues = lapply(sportData$leagues, function(leagueElement) {
      leagueElement$LeagueName <-
        leagues$LeagueName[leagueElement$id == leagues$LeagueID]
      leagueElement
    })
    
    # convert odds to dataframe
    oddsData <-
      suppressWarnings(JSONtoDF(removeNullFromList(sportData)))
    
    # Fixtures
    fixtures <-
      suppressMessages(getFixturesFast(sportID, leagueid = leagues$LeagueID, since = sinceTimeFixtures))
    #sinceTimeFixtures <- fixtures$Last[1]
    # Join Odds and Fixtures
    fixtodds <-
      right_join(
        fixtures,
        oddsData,
        by = c(
          "SportID" = "sportId",
          "LeagueID" = "id",
          "EventID" = "id.1"
        )
      )
    names(fixtodds)[names(fixtodds) == 'number'] <- 'PeriodNumber'
    
    #reorder fields
    orderNameFields <- c(
      'StartTime',
      'cutoff',
      'SportID',
      'LeagueID',
      'LeagueName',
      'EventID',
      'lineId',
      'PeriodNumber',
      'HomeTeamName',
      'AwayTeamName',
      'Status',
      'LiveStatus',
      'ParlayStatus',
      'RotationNumber'
    )
    newOrderFields <-
      c(orderNameFields[orderNameFields %in% names(fixtodds)],
        setdiff(names(fixtodds), orderNameFields[orderNameFields %in% names(fixtodds)]))
    fixtodds <- fixtodds[newOrderFields]
    
    # filter for main period and live games
    #oddsFiltered <- fixtodds %>%
    #  # Only Period "0", the main period
    #  filter(PeriodNumber == 0) %>%
    #  # No Corners
    #  filter(. ,!grepl("Corner", HomeTeamName)) %>%
    #  # No Live Games
    #  filter(is.na(awayScore))
    # filter out live games
    #livegames<-suppressWarnings(getInrunningFast(sportid))
    #oddsFiltered<-anti_join(oddsFiltered,livegames,by=c("id"="LeagueID","id.1"="EventID"))
    oddsFiltered <- fixtodds
    
    # colnames
    names(oddsFiltered)[names(oddsFiltered) == 'Last'] <-
      "LastFixtures"
    
    # append timestamp
    oddsFiltered <- cbind(timestamp = Sys.time(), oddsFiltered)
    
    # append to table
    if (is.null(ticksDF))
      ticksDF <- oddsFiltered
    else
      ticksDF <- merge(ticksDF, oddsFiltered, all = T)
    
    # create backup file
    #tname <- paste0("ticks", ncol(oddsFiltered))
    #dbWriteTable(con, tname, oddsFiltered, append = T)
    file.copy(dbfilename, paste0(dbfilename, "_backup"), overwrite = T)
    
    # save db to disc
    save(ticksDF, file = dbfilename)
    #sqliteCopyDatabase(con, dbfilename)
  },
  #
  # on error catch with saving workspace
  #
  error = function(e) {
    print(e)
    wsfilename = paste0("workspace",
                        format(Sys.time(), "%Y-%m-%dT%H-%M"),
                        ".RData")
    cat(paste("Saving Wortkspace to file", wsfilename, "..."))
    #save.image(file = wsfilename)
  })
  
  #
  # wait until end of cycle
  #
  loopcounter <- loopcounter + 1
  w <- as.numeric(cycletime) - as.numeric(Sys.time())
  cat(paste0(
    "Loop ",
    loopcounter,
    "@",
    Sys.time(),
    ": waiting for ",
    round(w, 2),
    " secs...\n"
  ))
  Sys.sleep(w)
}

# Disconnect from the database
#dbDisconnect(con)
