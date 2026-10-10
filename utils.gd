extends Node3D

@warning_ignore("unused_signal")
signal chunk_task_completed(tasks_completed: int)
signal chunk_task_count_found(total_tasks: int)
signal chunk_generated(gen_time: int)

var debug := true

#static func parse_time(time: int) -> String:
	#var MICRO: int = 1
	#var MILLISECOND: int = 1000
	#var SECOND: int = 1000 * MILLISECOND
	#var MINUTE: int = 60 * SECOND
	#var HOUR: int = 60 * MINUTE
	#
	#if time < MILLISECOND:
		#return "%s μs" % time
	#elif time < SECOND:
		#return "%s ms" % (time / MILLISECOND)
	#elif time < MINUTE:
		#return "%s s" % (time / SECOND)
	#elif time < HOUR:
		#return "%s min" % (time / MINUTE)
	#else:
		#return "%s h" % (time / HOUR)
