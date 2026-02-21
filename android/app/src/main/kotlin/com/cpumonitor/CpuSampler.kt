package com.cpumonitor

import android.app.ActivityManager
import android.content.Context
import java.io.File

data class ProcessCpu(val pid: Int, val name: String, val cpuPercent: Double)

/**
 * Samples CPU usage for running app processes only (via ActivityManager),
 * rather than iterating all of /proc. This keeps the sampler cheap enough
 * to run every few seconds without itself becoming a CPU hog.
 *
 * CPU% is computed as a delta of per-process jiffies vs total system jiffies
 * between two consecutive calls — same approach as `top`.
 *
 * First call primes the baseline and returns an empty list.
 */
object CpuSampler {

    private data class ProcStat(val total: Long, val idle: Long)
    private data class PidJiffies(val total: Long)

    private var prevSystem: ProcStat? = null
    private val prevPidStats = mutableMapOf<Int, PidJiffies>()

    @Synchronized
    fun sample(context: Context): List<ProcessCpu> {
        val currentSystem = readSystemStat()
        val prevSys = prevSystem
        prevSystem = currentSystem

        // First call: prime baselines, return nothing
        if (prevSys == null) {
            primeFromActivityManager(context)
            return emptyList()
        }

        val deltaTotal = (currentSystem.total - prevSys.total).coerceAtLeast(1L)

        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val runningProcesses = am.runningAppProcesses ?: return emptyList()

        val results = mutableListOf<ProcessCpu>()
        val livePids = mutableSetOf<Int>()

        for (proc in runningProcesses) {
            val pid = proc.pid
            livePids.add(pid)

            val current = readPidJiffies(pid) ?: continue
            val name = proc.processName.substringAfterLast(":")  // trim :service suffixes
                .substringAfterLast(".")                          // trim package prefix

            val prev = prevPidStats[pid]
            if (prev != null) {
                val deltaJiffies = (current.total - prev.total).coerceAtLeast(0L)
                val cpuPercent = (deltaJiffies.toDouble() / deltaTotal) * 100.0
                if (cpuPercent >= 1.0) {
                    results.add(ProcessCpu(pid, name, cpuPercent))
                }
            }
            prevPidStats[pid] = current
        }

        prevPidStats.keys.retainAll(livePids)
        results.sortByDescending { it.cpuPercent }
        return results
    }

    private fun primeFromActivityManager(context: Context) {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val procs = am.runningAppProcesses ?: return
        for (proc in procs) {
            val jiffies = readPidJiffies(proc.pid) ?: continue
            prevPidStats[proc.pid] = jiffies
        }
    }

    private fun readSystemStat(): ProcStat {
        return try {
            val line = File("/proc/stat").bufferedReader().readLine() ?: return ProcStat(1, 0)
            val parts = line.trim().split("\\s+".toRegex()).drop(1).map { it.toLongOrNull() ?: 0L }
            ProcStat(parts.sum(), parts.getOrElse(3) { 0L })
        } catch (_: Exception) {
            ProcStat(1, 0)
        }
    }

    private fun readPidJiffies(pid: Int): PidJiffies? {
        return try {
            val text = File("/proc/$pid/stat").readText()
            val afterParen = text.lastIndexOf(')') + 2
            val parts = text.substring(afterParen).trim().split(" ")
            val utime = parts.getOrNull(11)?.toLongOrNull() ?: return null
            val stime = parts.getOrNull(12)?.toLongOrNull() ?: return null
            PidJiffies(utime + stime)
        } catch (_: Exception) {
            null
        }
    }
}
