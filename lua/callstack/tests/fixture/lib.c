/* Fixture for the callstack tests.
 *
 * A diamond, so more than one path reaches the same entry point:
 *
 *      main
 *     /  |  \
 * top_1 top_2 top_3
 *     \  / \  /
 *    mid_a  mid_b
 *        \  /
 *         leaf
 *
 * plus a self-recursive function, which a naive upward walk never escapes.
 */

int leaf(int x)
{
	return x + 1;
}

int mid_a(int x)
{
	return leaf(x);
}

int mid_b(int x)
{
	return leaf(x) + leaf(x + 1);
}

int top_1(int x)
{
	return mid_a(x);
}

int top_2(int x)
{
	return mid_a(x) + mid_b(x);
}

int top_3(int x)
{
	return mid_b(x);
}

int recur(int n)
{
	return n <= 0 ? leaf(0) : recur(n - 1);
}

int uses_recur(void)
{
	return recur(5);
}

/* nothing calls this, so it must report no callers */
int orphan(void)
{
	return 0;
}

/* Indirect dispatch through an ops struct, the way ostor does it.  clangd
 * reports the *assignment* as an incoming call, so hidden() looks like it is
 * called from ops_init when in truth ops_init only stores its address and the
 * real call happens in ops_call through the pointer.
 */
struct ops {
	int (*get)(int);
};

static int hidden(int x)
{
	return x + 2;
}

void ops_init(struct ops *o)
{
	o->get = hidden;
}

int ops_call(struct ops *o)
{
	return o->get(1);
}

int main(void)
{
	return top_1(1) + top_2(2) + top_3(3) + uses_recur();
}
