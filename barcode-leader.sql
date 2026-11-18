-- BARCODE + ROLE LEADER + FOTO PENGELUARAN. Jalankan SEKALI di SQL Editor.

-- 1. Peran Leader
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('petugas','admin','superadmin','security','leader'));

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('petugas','admin','superadmin','leader'), false)
$$;

-- Leader tidak boleh mencatat barang masuk
drop policy if exists batches_insert on public.batches;
create policy batches_insert on public.batches for insert to authenticated
  with check (public.my_role() in ('petugas','admin','superadmin'));

-- 2. Barcode dan kode sistem per batch
alter table public.batches add column if not exists barcode text;
alter table public.batches add column if not exists code text;
create sequence if not exists public.batch_code_seq;
update public.batches set code = 'B' || lpad(nextval('public.batch_code_seq')::text, 6, '0') where code is null;
create unique index if not exists batches_code_key on public.batches(code);
create index if not exists batches_barcode_idx on public.batches(barcode);

create or replace function public.batch_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.stock := new.qty;
  new.created_by := auth.uid();
  new.code := 'B' || lpad(nextval('public.batch_code_seq')::text, 6, '0');
  return new;
end $$;

-- 3. Foto pengeluaran
alter table public.moves add column if not exists photo text;

drop function if exists public.do_outbound(uuid, numeric, text, text);
create or replace function public.do_outbound(p_batch uuid, p_qty numeric, p_party text, p_doc text, p_photo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_staff() then raise exception 'Tidak diizinkan'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if public.my_role() = 'leader' and (p_photo is null or p_photo = '') then
    raise exception 'Foto pengeluaran wajib untuk Leader';
  end if;
  update public.batches set stock = stock - p_qty where id = p_batch and stock >= p_qty;
  if not found then raise exception 'Stok tidak cukup'; end if;
  insert into public.moves(type, batch_id, qty, party, doc, photo, created_by)
  values ('out', p_batch, p_qty, p_party, p_doc, p_photo, auth.uid());
end $$;
revoke execute on function public.do_outbound(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.do_outbound(uuid, numeric, text, text, text) to authenticated;
