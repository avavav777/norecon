#!/usr/bin/env hy

(require [hy.extra.anaphoric [*]]
         [helpers [*]]
         )

(import os
        logging
        sys
        argparse
        json
        pprint
        subprocess
        tempfile

        [retry [retry]]
        [helpers [*]]
        [xml.etree.ElementTree :as xml]
        )

(defn parse-service
  [port-info]
  {"port" (port-info.get "portid")
   "protocol" (port-info.get "protocol")
   "state" (-> (port-info.find "state")
               (.get "state"))
   "service" (some-> (port-info.find "service")
                     (as-> $
                           {"type" ($.get "name")
                            "product" ($.get "product")
                            "finger-print" ($.get "servicefp")
                            "version" ($.get "version")
                            "extra" ($.get "extrainfo")
                            "device-type" ($.get "devicetype")}))})

(defn parse-nmap-xml
  [fp]
  "解析nmap输出的xml格式"
  (-> (lfor host (-> (xml.parse fp)
                     (.getroot)
                     (.iter "host"))
            {"ip" (-> (host.find "address")
                      (.get "addr"))
             "host" (some-> (host.find "hostnames/hostname")
                            (.get "name"))
             "ports" (->> (host.findall "ports/port")
                          (map parse-service)
                          list)})
      (sorted :key #%(of %1 "ip"))
      (group-by :key #%(of %1 "ip"))
      (->2> (lfor [ip datas]
                  ;; 注意迭代时iterator只能读取一次，然后数据为空
                  (as-> (list datas) datas
                        {"ip" ip
                         "host" (some-> (first datas)
                                        (.get "host"))
                         "ports" (->> datas
                                      (map #%(.get %1 "ports"))
                                      unpack-iterable
                                      concat)})))))

(defn masscan
  [ip &optional [port "0-65535"] [rate 10000] [timeout 300] [opts []]]
  "`opts` 传递给masscan的额外参数"
  (logging.info "masscan ip %s, rate:%s timeout:%s" ip rate timeout)
  (setv [_ out-fname] (tempfile.mkstemp ".xml" f"masscan_{ip}"))
  (try (subprocess.run ["masscan" "-p" port "-oX" out-fname "--rate" (str rate)
                        #* opts
                        ip]
                       :timeout timeout)
       (parse-nmap-xml out-fname)
       (except [subprocess.TimeoutExpired]
         (logging.warn "masscan %s timeout." ip))
       (finally
         (os.unlink out-fname))))

(defn nmap
  [ip &optional [port "0-65535"] [timeout 300] [opts []]]
  "`opts` 传递给nmap的额外参数"
  (logging.info "nmap ip %s, ports:%s timeout:%s" ip port timeout)
  (setv [_ out-fname] (tempfile.mkstemp ".xml" f"nmap_{ip}"))
  (try (subprocess.run ["nmap" "-v0" "-Pn" "--open" "-p" port
                        #* opts
                        "-sV" "-oX" out-fname
                        ip]
                       :timeout timeout)
       (parse-nmap-xml out-fname)
       (except [subprocee.TimeoutExpired]
         (logging.warn "nmap scan %s timeout." ip))
       (finally
         (os.unlink out-fname))))

(defn service-scan
  [ip &optional [masscan-kwargs {}] [nmap-kwargs {}]]
  (->> (masscan ip #** masscan-kwargs)
       (map #%(nmap (of %1 "ip")
                    :port (->> (of %1 "ports")
                               (map #%(of %1 "port"))
                               (str.join ","))
                    #** nmap-kwargs))
       unpack-iterable
       concat))

(defmain [&rest args]
  (logging.basicConfig :level logging.INFO
                       :handlers [(logging.FileHandler :filename "nmap_app.log")
                                  (logging.StreamHandler sys.stderr)]
                       :style "{"
                       :format "{asctime} [{levelname}] {filename}({funcName})[{lineno}] {message}")

  (setv opts (parse-args [["-t" "--timeout"
                           :type int
                           :default 20
                           :help "扫描超时时间(s) (default: %(default)s)"]
                          ["-r" "--rate"
                           :type int
                           :default 10000
                           :help "masscan扫描速率 (default: %(default)s)"]
                          ["-i" "--ips"
                           :nargs "?"
                           :type (argparse.FileType "r")
                           :default sys.stdin
                           :help "输入的ip"]
                          ["-d" "--output-dir"
                           :type str
                           :default "./"
                           :help "输出ip服务详情的目录，每个ip保存为一个文件,默认为当前目录"]
                          ["ip" :nargs "*" :help "要扫描的ip"]
                          ]
                         (rest args)
                         :description "扫描指定ip的服务"))

  (setv ips  (if (opts.ips.isatty)
                 (if opts.ip
                     opts.ip
                     (read-valid-lines opts.ips))
                 (+ opts.ip
                    (read-valid-lines opts.ips))))

  (os.makedirs opts.output-dir :exist-ok True)

  (-> ips
      (->> (map #%(service-scan %1
                                :masscan-kwargs {"timeout" opts.timeout
                                                 "rate" opts.rate}
                                :nmap-kwargs {"timeout" opts.timeout})))
      (doto (->> (list ) (print "result:")))
      (as-> infos
            (for [r infos]
              (json.dumps r (->> (of r "ip")
                                 (str.format "{}.json")
                                 (os.path.join opts.output-dir))))))
  (logging.info "over!")
  )
